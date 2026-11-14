# Text rendering performance

How Gooey places text on the glyph hot path, which optimizations it carries, and which were
measured and rejected. Updated 2026-11-14 for v0.5.1.

The 0.3.1 version of this document described `renderText`, which emitted glyphs into the
0.3.1 scene; phase 6 removed that path (#218). The measurements below were taken on it.
The phases they describe carried over unchanged to `placeText`; git history keeps the
full write-up.

## The path

`text.render.placeText` (`src/text/render.zig`) shapes a run and hands each placed glyph to
its caller's sink. The core's emit (`emitTextBaseline` in `src/core/emit.zig`) is the only
caller; its sink appends one sprite paint record per glyph to the frame being built, which
pack later turns into instances of the packed frame's glyph pipeline.

1. **Shape.** `TextSystem.shapeTextInto` shapes into a stack buffer of at most
   `MAX_GLYPHS_PER_RUN` glyphs. A shape-cache hit copies the cached run and allocates
   nothing; only a miss uses the text system's run allocator.
2. **Positions.** `computeGlyphDevicePositions` computes device-pixel positions and
   subpixel offsets for every glyph, with no lock.
3. **Resolve.** `TextSystem.resolveGlyphBatch` takes `glyph_cache_mutex` once per batch
   and looks up or rasterizes every glyph in it.
4. **Place.** `placeGlyph` snaps each glyph to device pixels and passes it to the sink,
   with no lock.

A comptime assertion in `render.zig` keeps the run's stack buffers under 16 KiB, so a
deep tick stays inside the 1 MiB WASM stack (CLAUDE.md §14).

## What landed

- **One lock per batch instead of one per glyph** (`TextSystem.resolveGlyphBatch`): 4.66
  against 9.23 ns per warm glyph.
- **A cheaper `GlyphKey` hash** (`cache.zig`, `GlyphKey.hash`): the non-pointer fields are
  packed into one `u64` and mixed with the font pointer in two multiply rounds, replacing a
  byte-by-byte FNV chain. Covered by `glyph_warm_*`.
- **O(1) glyph-cache insert** (`cache.zig`, `free_chain` and `next_free`): a free list
  replaces a linear scan for an empty slot. Covered by `glyph_raster_cold_ascii`.
- **Separate loops for positions, resolve, and place** (`render.zig`, `placeText`).

The free list has one invariant every new eviction path must keep: a slot whose entry
becomes invalid goes back on `free_chain`, or the cache leaks capacity.

## What was rejected

Two changes to the per-glyph emit loop were built, measured, and dropped:

- **Hoisting the UV and scale divisions** into per-run reciprocals. The atlas can change
  size in the middle of a resolve, so the hoisted value needs a per-glyph guard, and that
  branch cost about 0.5 ns per glyph more than the divisions it saved.
- **Batching the scene insert** through a temporary buffer. It doubled the memory traffic
  per glyph and ran about twice as slow; a single-pass batch came back level.

Both measured the same floor: about 3.1 ns per glyph on Apple silicon, set by one store
per glyph rather than by arithmetic or bookkeeping. Future wins should cut the number of
glyphs emitted, for example by culling runs outside their clip or by caching whole runs,
rather than shave the per-glyph cost. The benchmarks that showed this
(`emit_div_ascii_x20` and `emit_hoisted_ascii_x20`) are not in the tree; re-adding them is
the first step if the place loop is revisited. Write the candidate as a bench-local copy of
the place loop: calling the real loop across the module boundary measures call overhead
instead, which once reported a false 2× regression.

## Benchmarks

```sh
zig build bench-text                        # shaping, measuring, and glyph resolve
zig build bench-text -Dbench-json-dir=out   # JSON for bench-compare
```

`src/text/benchmarks.zig` covers shaping (`shape_cold_*`, `shape_warm_*`), measuring
(`measure_*`), and the glyph cache: `glyph_warm_perglyph_ascii_x20` against
`glyph_warm_batch_ascii_x20` gates the batched lock, and `glyph_raster_cold_ascii` the
free-list insert. Nothing benchmarks `placeText` end to end since the 0.3.1
`render_text_*` cases went with `renderText`.
