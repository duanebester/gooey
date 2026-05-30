# Scene Data-Plane Performance

Benchmark notes and design analysis for the scene → batch → frame pipeline
(`src/scene/`), the data plane that feeds the GPU. Companion to
`text-rendering-performance.md`; numbers are produced by
`src/scene/benchmarks.zig` (`zig build bench-scene`).

## Context

The existing suites (`bench`, `bench-context`, `bench-core`, `bench-text`)
thoroughly cover the **control plane** — layout, the dispatch tree, core
geometry, text shaping/glyph caching. What was unbenched until now is the
**data plane**: the scene assembly that turns those results into GPU
instances, batches them in draw order, and drains them per frame.

This is exactly the gap `CLAUDE.md` §7 ("how many vertices / texture uploads
per frame?") and §8 ("batching is religion") call out. `bench-scene` measures
it directly: the per-frame instance emission, how cleanly primitives batch,
the draw-order sort, the clip stack, and the end-to-end frame against the
frame budget.

**Scope.** This measures the headless scene→batch portion of the frame. The
platform/GPU submission in `runtime/frame.zig` needs a live window, a Metal
device, and the CoreText stack, so it cannot run in a headless benchmark. The
scene data plane is the part that is both measurable here and the
GPU-bandwidth proxy.

---

## The suite

Run: `zig build bench-scene` (add `-Dbench-json-dir=<dir>` to capture JSON).
Validate (Debug, assertions live): the `validate:` tests in
`src/scene/benchmarks.zig` run under `zig build test` — they check primitive
counts, batch coalescing, sort correctness, clip balance, and the
**steady-state zero-allocation invariant** via a counting allocator.

| Group           | What it times                                         | Reports                              |
| --------------- | ----------------------------------------------------- | ------------------------------------ |
| Scene build     | `clear()` + `insertQuad`/`insertGlyph`/`insertShadow` | ns / primitive emitted               |
| Batch iteration | `BatchIterator.next()` drain of a finished scene      | ns / primitive + **batch count**     |
| Draw-order sort | `finish()` pdq over a shuffled quad array             | ns / quad sorted                     |
| Clip stack      | `pushClip` (with intersection) + `popClip` pairs      | ns / nesting level                   |
| Frame e2e       | `clear → build → finish → drain`                      | whole-frame µs (avg + p99) vs budget |

All groups collect p50/p99 percentiles; the regression gate
(`bench-compare`) classifies on the best-of-N minimum.

---

## Results (macOS arm64, M-series, `ReleaseFast`)

These are the shape of the curve, not acceptance criteria.

### Scene build — flat ~4 ns/primitive, zero allocations

| Test                  | Ops   | ns/op | p99   |
| --------------------- | ----- | ----- | ----- |
| build_quads_256       | 256   | 3.98  | 4.72  |
| build_quads_2k        | 2000  | 4.37  | 8.40  |
| build_quads_16k       | 16000 | 4.32  | 5.59  |
| build_glyphs_16k      | 16000 | 4.06  | 5.33  |
| build_interleaved_2k  | 4000  | 9.45  | 13.35 |
| build_dashboard_large | 5041  | 3.94  | 5.51  |

Flat from 256 → 16k primitives with no super-linear creep; the passing
zero-alloc test confirms the static-allocation policy (§2) holds in steady
state — no per-insert growth jitter. Interleaved emission is ~2× because it
bounces between two append targets (cache lines for the quad and glyph
arrays).

### Batch iteration — coalescing quantified

| Test                   | Ops   | ns/op | Batches |
| ---------------------- | ----- | ----- | ------- |
| batch_quads_16k        | 16000 | 1.00  | 1       |
| batch_glyphs_16k       | 16000 | 0.94  | 1       |
| batch_interleaved_2k   | 4000  | 19.89 | 4000    |
| batch_dashboard_medium | 1537  | 2.39  | 145     |
| batch_dashboard_large  | 5041  | 2.08  | 361     |

This is the §8 batching thesis made concrete: coalesced same-type primitives
drain at ~1 ns each in a single batch; fully-interleaved primitives cost ~20×
because each `next()` carries a fixed 9-primitive-type scan and emits one
batch per primitive. Realistic mixed scenes land at ~2 ns/prim with healthy
batch sizes (avg ~14).

### Draw-order sort — the one hot spot

| Test           | Ops   | ns/quad | per `finish()` |
| -------------- | ----- | ------- | -------------- |
| sort_quads_1k  | 1000  | 354.6   | ~0.35 ms       |
| sort_quads_8k  | 8000  | 410.5   | ~3.3 ms        |
| sort_quads_32k | 32000 | 457.2   | **~14.6 ms**   |

Per-quad cost scales sub-linearly (correct for a comparison sort), but the
**constant is high**: `std.sort.pdq` moves whole 128-byte `Quad` structs
(`QUAD_SIZE` in `core/limits.zig`). A large out-of-order scene can consume an
entire 60 Hz frame in the sort alone. See the analysis and fix below.

**Resolved (indirect key sort).** `finish()` now sorts compact `(order, index)`
u64 keys and gathers the payload once (see "Recommended optimization" below).
The `sort_struct_quads_*` entries keep the old payload sort as a side-by-side
baseline. Measured on the same shuffled inputs (M-series, `ReleaseFast`):

| Test           | Ops   | payload ns/quad | keyed ns/quad | speedup |
| -------------- | ----- | --------------- | ------------- | ------- |
| sort_quads_1k  | 1000  | ~233            | ~20           | ~11.8×  |
| sort_quads_8k  | 8000  | ~274            | ~49           | ~5.6×   |
| sort_quads_32k | 32000 | ~303            | ~58           | ~5.2×   |

`bench-compare` records this as −80% to −92% on the gated minimum, 0 regressed.
The 32k sort drops from ~9.7 ms to ~1.9 ms — back under a single frame.

### Clip stack — negligible

5–9.5 ns per push/pop pair (depths 8/16/32) — essentially at timer
resolution. Not a concern.

### Frame e2e — data plane is <0.4% of budget

| Test                   | Prims | Batches | Avg/frame | p99/frame | % 60 Hz | % 120 Hz |
| ---------------------- | ----- | ------- | --------- | --------- | ------- | -------- |
| frame_dashboard_small  | 265   | 37      | 1.83 µs   | 2.17 µs   | 0.01%   | 0.02%    |
| frame_dashboard_medium | 1537  | 145     | 9.21 µs   | 17.71 µs  | 0.06%   | 0.11%    |
| frame_dashboard_large  | 5041  | 361     | 30.73 µs  | 44.46 µs  | 0.18%   | 0.37%    |

The frame group uses in-order builds (no overlays), so it exercises the
no-sort happy path. The takeaway: scene assembly is not where the frame
budget goes — layout, text shaping, and GPU submission are. Tails are tight
(build/batch p99 ≈ 1.2–1.5× p50), which is what frame pacing needs.

---

## External validation

The numbers were cross-checked against published claims. gooey's scene
primitives are directly modeled on GPUI, so it is the primary reference.

### Frame budget (GPUI / Zed)

The GPUI rendering blog opens with _"an application only has **8.33 ms** per
frame to push pixels to screen"_ — exactly our 120 Hz budget. Our 5041-prim
frame at 30.7 µs (**0.37%** of 8.33 ms) is consistent with GPUI's thesis that
scene assembly is cheap and the budget is spent elsewhere.

### Draw order (GPUI)

GPUI: _"starts by drawing all shadows, followed by all rectangles, then all
glyphs… a rectangle could never be rendered on top of a glyph."_ That is
exactly gooey's `BatchIterator` tie-break (`shadow < quad < glyph < svg <
image < …`), and GPUI's `Layer { shadows, rectangles, glyphs, … }` mirrors
gooey's per-type arrays. The lineage is faithful.

**The divergence that explains our sort cost:** GPUI avoids per-primitive
order-sorting entirely — it uses fixed type order plus coarse
layers/stacking contexts for z-ordering. gooey generalized that into a
per-primitive `order` field plus an interleaving iterator. More flexible, but
it is what introduces the sort (and the interleaved worst case).

### Sorting (Christer Ericson, "Order your graphics draw calls around!", 2008)

The canonical draw-call-sorting reference says to sort an array of
**`(key, value)` pairs where the value is a pointer/offset** to the draw-call
data — never the payload. His claim: _"there really is no problem sorting
**5,000 or even 10,000 draw calls** each frame this way"_ on **2008-era PS3**
hardware.

We sort 8k on a modern M-series and it costs 3.3 ms — the gap is almost
entirely because we move 128-byte structs where he moves tiny keys. This both
corroborates the hot-spot finding and prescribes the fix.

### Rebuild-every-frame (Dear ImGui)

The IMGUI paradigm builds draw data fresh each frame (_"most is built up every
frame"_). Our `clear() + rebuild` at flat ~4 ns/prim with zero allocations is
the cheap rebuild that model assumes — and the zero-alloc test proves we avoid
the GC/allocation jitter the GPUI blog blames for Electron's missed frames.

> Caveat: Ericson's numbers are 2008 PS3 SPUs; GPUI's are modern Macs. Treat
> absolute cross-era figures as order-of-magnitude sanity checks. The
> structural claims (same draw order as GPUI, sort keys not payloads, 8.33 ms
> budget) are the robust takeaways.

---

## Correctness gaps found while benchmarking

Benchmarking the sort path surfaced two defects in `Scene.finish()`
(`src/scene/scene.zig`). Neither is a performance issue per se, but both live
on the sort path the optimization below rewrites, so they are fixed in the
same pass.

### Colored point clouds are never sorted (dead invariant)

`finish()` sorts 8 of the 9 primitive types. The 9th —
`colored_point_clouds` — is missing a branch:

- `insertColoredPointCloudWithOrder` sets `needs_sort_colored_point_clouds = true`.
- `clear()` resets the flag.
- `finish()` never reads it.

The flag is therefore write-only. Any out-of-order colored-point-cloud insert
renders in insertion order rather than draw order. This is precisely the §11
"negative space" failure mode: the valid state is handled and the flag
exists, but the path that consumes it was never wired up. Fix: add the
missing sort branch, and extend the `validate:` suite with a sort-correctness
check that covers **all nine** types (the current tests miss this one).

**Fixed.** `finish()` now wires in the `colored_point_clouds` branch, and a new
`scene.zig` test ("finish sorts all nine per-type draw-order arrays ascending")
seeds every array out of order and asserts ascending order — plus a parallel
gather check that each path gradient still travels with its instance.

### The paths sort is O(n²)

`needs_sort_paths` uses a hand-rolled in-place **selection sort** because
`path_instances` and `path_gradients` are parallel arrays that must be
permuted together. The inline comment ("path counts are typically small, so
O(n²) is acceptable") is a latent tail-latency landmine — exactly the §1/§4
"fix it now, put a limit on everything" case. The key-sort scheme below
solves it cleanly: sort `(order, index)` keys once, then gather _both_
parallel arrays with the same permutation.

**Fixed.** `sortPathsByOrder` sorts a stack-local key buffer (paths are bounded
by `MAX_PATHS_PER_FRAME`, so 32 KB of keys covers the worst case with no heap
scratch) and gathers `path_instances` + `path_gradients` with one permutation —
O(n log n), selection sort retired.

---

## Recommended optimization: sort keys, not payloads

`Scene.finish()` currently calls `std.sort.pdq` directly over the
`ArrayListUnmanaged(Quad)` (and the other per-type arrays), so every swap
moves a 128-byte `Quad`. The textbook fix (Ericson's `(key, value)` scheme)
is to sort a compact key array and gather:

1. Build a scratch `[]struct { order: u32, index: u32 }` (8 bytes/entry vs 128) — or pack `order` and `index` into a single `u64` key.
2. `pdq` the key array (8× fewer bytes moved per swap, cache-resident).
3. Gather the payload array into sorted position once, in a single linear
   pass.

Expected win: ~10× on the sort path (sorting 8-byte keys instead of 128-byte
structs), which would bring an 8k-quad sort from ~3.3 ms toward the
sub-millisecond range Ericson describes.

**Make it generic, not quad-only.** `Quad` is the worst offender at 128 B,
but `GlyphInstance` is also a fat struct and `bench-glyphs` reaches 16k —
every array that triggers a sort pays the payload-move tax. Write the scheme
once as a helper (`sortByOrder(comptime T, items, scratch_keys)`) and route
all single-array types through it (shadows, quads, glyphs, svgs, images,
polylines, point clouds, colored point clouds). The parallel paths arrays
reuse the _same_ key permutation to gather `path_instances` and
`path_gradients` together — retiring the O(n²) selection sort noted above.

**Mind the gather step (§2 / §7).** The key sort is cache-resident and
cheap, but landing the sorted payloads needs care to stay on the
static-allocation path:

- A scratch copy of the payload array is simplest but reserves
  `MAX_QUADS_PER_FRAME × 128 B` (and equivalents per type) of static memory.
- In-place cycle-following permutation avoids the second full-size buffer at
  the cost of more complex gather logic.

Sketch both against the per-frame memory budget before committing; the key
arrays themselves are fixed-capacity (bounded by the per-type `MAX_*`
limits), so they stay on the static-allocation path regardless.

This only affects scenes that trigger the sort (`insertQuadWithOrder`,
overlays, canvas z-ordering); the common in-order frame never sorts. But it
removes a latent tail-latency spike that scales straight into the frame budget
for overlay-heavy scenes.

**Gating:** `bench-scene` already measures `sort_quads_{1k,8k,32k}`. Add an
index-sort-vs-struct-sort comparison entry on the same shuffled inputs to size
the win on our hardware and let `bench-compare` lock it in.

**Implemented.** `Scene.sortByOrder(comptime T, items)` packs `(order, index)`
into a single `u64` (order high, index low — a stable, deterministic tie-break)
and applies the sorted permutation in place by **cycle-following** (`PERM_DONE`
sentinel marks placed slots), so each payload moves at most once and no
second full-size payload buffer is needed. The key scratch is a single shared
`sort_keys` buffer pre-sized to `MAX_SORT_KEYS` by `initCapacity` (grown-and-
retained by `init()` scenes), keeping `finish()` allocation-free in steady
state; a payload-`pdq` fallback covers the rare case where the scratch can't be
acquired, so `finish()` stays infallible. All eight single-array types route
through the helper; paths use the parallel-gather variant. Gating entries
`sort_struct_quads_{1k,8k,32k}` were added — see the results table above.

## Secondary: collapse the double min-scan in `BatchIterator.next()`

Lower priority, and only relevant to the interleaved worst case (~20×
slower, one batch per primitive). Each `next()` computes the minimum order
across all 9 types via a 9-way scan to pick the batch kind, then
`consumeBatch` runs a _second_ 8-way `minOfOrders` to find the threshold
(the second-smallest order) at which the batch must stop. That is two passes
to compute the smallest and second-smallest order per batch. Folding the
threshold into the same scan that finds the min would roughly halve the
per-`next()` overhead. Realistic mixed scenes sit at ~2 ns/prim, so treat
this as an "if you're already in here" cleanup rather than a priority.

**Implemented.** `next()` now tracks the minimum and the second-smallest order
(`batch_threshold`) in a single pass and emits the batch through one
`inline else` switch arm; `minOfOrders` is retired. Same tie-break and batch
counts; the interleaved worst case dropped ~55% (13.1 → 5.9 ns/prim) and mixed
dashboard scenes ~1.5 → ~0.9 ns/prim.

---

## References

- Scandurra, A. _Leveraging Rust and the GPU to render user interfaces at
  120 FPS_ (GPUI), Zed, 2023 — <https://zed.dev/blog/videogame>
- Ericson, C. _Order your graphics draw calls around!_, 2008 —
  <https://realtimecollisiondetection.net/blog/?p=86>
- Dear ImGui — _About the IMGUI paradigm_ —
  <https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm>
- Source: `src/scene/benchmarks.zig`, `src/scene/scene.zig`,
  `src/scene/batch_iterator.zig`, `src/core/limits.zig`
- Baselines + regression workflow: `docs/benchmarks/README.md`
