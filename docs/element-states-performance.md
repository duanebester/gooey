# Element-State Pool Performance

Benchmark notes and design analysis for `src/context/element_states.zig` — the
keyed pool that backs `cx.with_element_state(...)` and holds every stateful
widget's retained state under a `(id_hash, type_id) -> *S` key. Companion to
`scene-data-plane-performance.md`; numbers are produced by
`src/context/element_states_benchmarks.zig` (`zig build bench-element-states`).

## Context

`ElementStates` is the pool PR 8 introduced to collapse the per-type widget maps
on the old `WidgetStore` (`text_inputs`, `text_areas`, `code_editors`,
`scroll_containers`, `select_states`) into one table. Its lookup runs once per
stateful widget per frame, so its hot path is a per-frame cost. `bench-context`
covers the dispatch tree and entity map; this suite isolates the pool.

The pool's lookup is an explicit linear scan, and `findIndex` says so:

> Linear scan over the dense prefix. O(count). … at this size the
> branch-predictor friendliness of the linear walk beats a hash map's
> pointer-chasing for the small-N case (most elements touch < 64 distinct
> states). **If a profile shows otherwise we can swap in an `AutoHashMap`** keyed
> by `Key.hash()` without changing the public surface.

`bench-element-states` *is* that profile. It measures lookup cost as a function
of occupancy and pins down exactly where the linear scan stops being the right
call — the same way the scene suite's sort measurement prescribed
sort-keys-not-payloads.

---

## The suite

Run: `zig build bench-element-states` (add `-Dbench-json-dir=<dir>` for JSON).
Validate (Debug, assertions live): the `validate:` tests run under `zig build
test` — lookup correctness, churn returning the pool to empty, and the
**steady-state zero-allocation invariant** via a counting allocator.

| Group | What it times | Reports |
| --- | --- | --- |
| Lookup vs occupancy | one `get` per present key at 8/64/512/4096 entries | ns / lookup |
| Get-or-create hit | one `withElementState` per present key | ns / lookup |
| Insert + remove | `count` `withElementState` misses + `remove`s | ns / (insert+remove) pair |

The lookup groups walk every present key once, so the scanned position averages
`occupancy/2` and the reported ns/op is the *average* lookup at that fill level.
All groups collect p50/p99; the gate classifies on the best-of-N minimum.

---

## Results (macOS arm64, M-series, `ReleaseFast`)

These are the shape of the curve, not acceptance criteria.

### Lookup vs occupancy — a clean O(count) line

| Test | Entries | ns/lookup | p99 | implied ns/comparison |
| --- | --- | --- | --- | --- |
| get_occupancy_8 | 8 | 3.60 | 10.50 | ~0.90 |
| get_occupancy_64 | 64 | 19.37 | 23.44 | ~0.61 |
| get_occupancy_512 | 512 | 123.21 | 135.42 | ~0.48 |
| get_occupancy_4096 | 4096 | 981.17 | 1010.17 | ~0.48 |

The average lookup scans `occupancy/2` entries, so dividing ns/lookup by that
gives the per-comparison cost — and it converges to **~0.48 ns per `Key.eql`**
(two `u64` compares) from 512 entries up. That is a textbook tight, cache-
resident, branch-predictor-friendly linear scan; the per-comparison cost is
*lower* at scale, not higher, because the loop amortizes its fixed overhead. The
small-N rows (~0.9 ns/cmp at 8) are dominated by that fixed overhead, not the
scan.

The number that matters is the absolute lookup cost at the top: **a single
lookup in a 4096-entry pool averages ~981 ns** because it walks ~2048 entries.

### Get-or-create hit — the real call site matches `get`

| Test | Entries | ns/lookup | p99 |
| --- | --- | --- | --- |
| with_hit_64 | 64 | 23.21 | 28.00 |
| with_hit_512 | 512 | 154.50 | 186.20 |

`withElementState` on a present key is `get` plus a capacity assert and the
comptime-`default` plumbing — ~20% over the bare `get` at the same occupancy,
same linear shape. This is the path `cx.with_element_state(...)` actually walks,
and the validate test confirms it **allocates zero** on the hit path.

### Insert + remove — the allocating control plane

| Test | Pairs | ns/pair | p99 |
| --- | --- | --- | --- |
| insert_remove_64 | 64 | 118.16 | 257.16 |
| insert_remove_512 | 512 | 319.01 | 402.18 |

The miss path is `create(S)` + a full scan (the key isn't there yet); `remove`
is a scan + swap-remove + `destroy`. This is the only group that touches the
heap, and at ~118–319 ns/pair it is dominated by the allocator, not the scan.
Widget mount/unmount churn, not steady-state polling, so this is a control-plane
cost (CLAUDE.md §8) and is expected to allocate.

---

## The O(count) scan becomes O(count²) per frame at the top end

The lookup is O(count). But a *frame* calls `withElementState` once per present
state, so a frame that touches all `N` states costs `N × O(N) = O(N²)`. Folding
the per-comparison constant (~0.48 ns) and the average scan length (`N/2`) in:

```
per-frame state lookup ≈ N × 0.24·N ns = 0.24·N² ns
```

| Distinct states in a frame | Full-frame state lookup | % of 60 Hz budget |
| --- | --- | --- |
| 64 | ~1.2 µs | 0.007% |
| 512 | ~63 µs | 0.4% |
| 4096 | ~4.0 ms | **24%** |

For the **common case the `findIndex` comment names — under ~64 distinct states —
the linear scan is the right answer**: ~1.2 µs/frame, and a hash map's hashing +
pointer-chasing would only add overhead at that size. But a pathological frame —
a 4096-row virtual list where every row is a distinct stateful widget — would
spend **~4 ms, a quarter of the 60 Hz budget, in state lookup alone.**

---

## Recommended optimization: hash-map the lookup above a threshold

`findIndex` already anticipates the fix and promises it costs nothing at the API
surface. This benchmark sizes it:

1. Add an `AutoHashMapUnmanaged(Key, u32)` (or `AutoArrayHashMapUnmanaged`) side
   index mapping `Key.hash()` → slot, maintained alongside the existing dense
   `entries` array (the array stays for dense iteration and swap-remove; the map
   only accelerates `findIndex`).
2. `get` / `withElementState` / `insert` / `remove` consult the map instead of
   scanning. Swap-remove updates one map entry (the moved tail's slot).

Expected win on the O(N²) frame: a hash lookup is ~O(1) at a fixed ~10–20 ns
regardless of `N`, so the full-frame 4096-state cost drops from **~4 ms toward
~60 µs (~65×)**. The map's memory is bounded by `MAX_ELEMENT_STATES` (4096), so
it stays on the static-allocation path (CLAUDE.md §2/§4).

**When to actually do it:** only if a real UI drives occupancy into the
hundreds-to-thousands of *distinct* states per frame (large virtual/uniform
lists where every row is independently stateful). Until then the linear scan
wins on constant factors for the <64 case, exactly as the comment claims — the
honest move is to keep the scan and let `bench-element-states` watch the curve.

**Gating:** `get_occupancy_{8,64,512,4096}` already captures the line. If
`findIndex` is hash-mapped, the high-occupancy entries should flatten from
~981 ns toward a constant; `bench-compare` will show that as a large
"improvement" and lock in the new shape.

---

## External validation

- **Linear scan vs hash map at small N.** The result that a flat linear scan
  beats a hash map below a few dozen elements — and that the crossover is in the
  tens-to-low-hundreds — is a well-worn systems result (constant factors and
  cache locality dominate at small N; this is why `std`-style flat maps and
  small-vector optimizations exist). The ~0.48 ns/comparison measured here is
  consistent with two L1-resident `u64` compares per step on M-series silicon.
- **Same discipline as the sibling pools.** `Globals` and `SubscriberSet` use the
  identical dense-prefix linear scan, deliberately (CLAUDE.md §1). A hash-map
  retrofit here would be the template for those too if their occupancy ever
  warrants it — but the same "measure first" rule applies; none is benched into
  the danger zone today.

---

## References

- Source: `src/context/element_states_benchmarks.zig`,
  `src/context/element_states.zig`
- Sibling pools sharing the linear-scan discipline:
  `src/context/global.zig`, `src/context/subscriber_set.zig`
- PR 8 rationale (unified element-state pool): `docs/cleanup-implementation-plan.md`
- Baselines + regression workflow: `docs/benchmarks/README.md`
