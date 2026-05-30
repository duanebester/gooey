# Benchmark Baselines

Frozen benchmark results captured after the Zig 0.16 `std.Io` migration
([`../zig-0.16-io-migration.md`](../zig-0.16-io-migration.md)) landed. These
files are the reference point for regression detection against future
changes — particularly changes that touch timing, allocation, mutex, or
async paths in the framework.

## What's here

Each file is produced by `src/bench/json_writer.zig` at the end of a
benchmark `main()`. The filename encodes the platform, module, and
capture date:

```
<os>-<arch>-<module>-benchmarks-<mm-dd-yyyy>.json
```

Modules captured:

| File                                                      | Source                                      | Entries |
| --------------------------------------------------------- | ------------------------------------------- | ------- |
| `macos-aarch64-layout-benchmarks-04-23-2026.json`         | `src/layout/benchmarks.zig`                 | 24      |
| `macos-aarch64-context-benchmarks-04-23-2026.json`        | `src/context/benchmarks.zig`                | 49      |
| `macos-aarch64-core-benchmarks-04-23-2026.json`           | `src/core/benchmarks.zig`                   | 59      |
| `macos-aarch64-text-benchmarks-04-23-2026.json`           | `src/text/benchmarks.zig`                   | 40      |
| `macos-aarch64-scene-benchmarks-05-30-2026.json`          | `src/scene/benchmarks.zig`                  | 23      |
| `macos-aarch64-animation-benchmarks-05-30-2026.json`      | `src/animation/benchmarks.zig`              | 9       |
| `macos-aarch64-element-states-benchmarks-05-30-2026.json` | `src/context/element_states_benchmarks.zig` | 8       |
| `macos-aarch64-accessibility-benchmarks-05-30-2026.json`  | `src/accessibility/benchmarks.zig`          | 7       |

Each entry carries `operation_count`, `total_time_ns`, `iterations`,
`avg_time_ms`, `time_per_op_ns`, and (where measured) `p50_per_op_ns` /
`p99_per_op_ns`. Comparisons are driven off `time_per_op_ns`, with p99
checked independently when present so tail-latency regressions surface
even when the average is steady.

## Capturing a new run

```sh
# Writes <os>-<arch>-<module>-benchmarks-<mm-dd-yyyy>.json into the target dir.
# Overwrites same-day files; date-stamps make month-over-month diffs trivial.
zig build bench-all -Dbench-json-dir=docs/benchmarks
```

Individual suites (`bench`, `bench-context`, `bench-core`, `bench-text`,
`bench-scene`, `bench-animation`, `bench-element-states`,
`bench-accessibility`) accept the same `-Dbench-json-dir=` flag — useful when
iterating on a single module.

All benchmarks build at `ReleaseFast`. Adaptive iteration counts target
~50 ms wall-clock per entry, so a full `bench-all` run is bounded at a
few minutes regardless of machine speed.

## Checking for regressions

```sh
# Default threshold: 15% slowdown on time_per_op_ns (or p99 when present).
zig build bench-compare -- \
  docs/benchmarks/macos-aarch64-layout-benchmarks-04-23-2026.json \
  path/to/fresh-layout-run.json

# Tighter threshold for CI-style gating:
zig build bench-compare -Dbench-threshold=10 -- baseline.json current.json
```

Exit code is `0` on pass, `1` on any regression above the threshold.
Output format: side-by-side table with per-entry delta plus a summary
line (`N compared | N regressed | N improved | N new | N removed`).

See `src/bench/compare.zig` for the full comparison logic. Entries that
appear only in one file are reported as "new" / "removed" — comparing
across module boundaries produces all-removed tables and a clean failure
mode rather than silently matching by prefix.

## When to refresh the baseline

Add a **new** file (don't overwrite the old one) when:

- The benchmark set itself changes — new entries added or old entries
  removed/renamed. The filename date stamp disambiguates, and keeping
  the old JSON means you can still diff historical runs against each
  other with `bench-compare`.
- An intentional perf change lands and you want future regressions
  measured against the new steady state. Capture on the merge commit
  and note the reason in your commit message.

Don't refresh for:

- Normal run-to-run variance (typically ±3–5% on `time_per_op_ns`, a bit
  more on low-iteration entries). The default 15% threshold is sized
  for this.
- Machine changes — a baseline captured on an M-series laptop is not
  comparable to one captured on x86_64 Linux, which is why the os/arch
  are baked into the filename. If you benchmark on a new machine, add
  a parallel baseline alongside the existing ones rather than
  replacing them.

## Interpreting the numbers

A few orientation points from the initial capture (macOS arm64, M-series,
`ReleaseFast`):

- **Layout** — full-frame (build + endFrame) costs ~70 ns/node across
  1k–15k node trees. Sub-linear scaling confirms sibling walks are
  O(1) after the `last_child` fix noted in `context/benchmarks.zig`.
- **Core** — `FixedArray.swapRemove` is ~0.4 ns/op vs
  `orderedRemove` at 27 ns/op (n=1000). Convex ear-clip is constant
  ~20 ns/op to 512 verts; concave (star) polygons go super-linear as
  the algorithm demands.
- **Text** — warm-path `shapeTextInto` with a stack-allocated glyph
  buffer hits ~14 ns/op on 13-char strings (290× faster than cold
  shape). `resolveGlyphBatch` under a single mutex lock is 44% faster
  than per-glyph locking for the same working set — this gap is what
  the `endFrame` render path exploits.
- **Context** — tree build is ~7–9 ns/op pushNode amortized, flat
  across widths up to 2000 siblings.
- **Scene (data plane)** — primitive emission is flat ~4 ns/op and
  allocation-free in steady state; `BatchIterator` drains coalesced
  scenes at ~1 ns/prim (1 batch) vs ~20 ns/prim when fully interleaved
  (1 batch/prim) — the cost of poor batching, quantified. `finish()`
  sorting 128-byte `Quad` structs is the one hot spot (~3.3 ms for 8k
  out-of-order quads); see `../scene-data-plane-performance.md`.
  A realistic 5k-primitive frame (build + finish + batch drain) is
  ~31 µs — under 0.4% of the 8.33 ms / 120 Hz budget.
- **Animation** — an at-rest spring tick is ~1.1 ns (a single branch),
  ~8× cheaper than the ~9 ns RK4 step it skips, so idle springs are
  effectively free; a 256-spring store frame is ~6 µs (0.04% of the
  60 Hz budget) and allocation-free in steady state. See
  `../animation-performance.md`.
- **Element states** — `get`/`withElementState` on a present key is an
  O(count) linear scan: ~3.6 ns at 8 entries but ~981 ns at 4096, a
  clean ~0.48 ns/comparison line that quantifies exactly when
  `findIndex` should become a hash map. Steady-state lookups allocate
  zero. See `../element-states-performance.md`.
- **Accessibility** — `fingerprint.compute` is ~1.4 ns; a full
  1000-element frame diff (snapshot + rebuild + dirty/removed) is
  ~128 µs (~0.8% of the 60 Hz budget), and content churn adds
  negligible cost on top. See `../accessibility-diff-performance.md`.

These are not acceptance criteria — they're the shape of the curve.
Regressions show up as shape changes, not absolute-number changes.

## Why this lives in `docs/`, not `bench-results/`

`bench-results/` is gitignored (see the root `.gitignore`) and treated
as scratch — the directory where you pipe output during a workday.
`docs/benchmarks/` is tracked precisely so these reference JSONs survive
`git clean -fdx` and show up in `git blame` when someone wonders why a
future comparison is being made against numbers from April 2026.
