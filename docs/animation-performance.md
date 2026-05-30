# Animation Performance

Benchmark notes and design analysis for the per-frame animation tick
(`src/animation/`): the spring physics (`spring.zig`), motion containers
(`motion.zig`), and the `AnimationStore` dispatch (`store.zig`) that polls them.
Companion to `scene-data-plane-performance.md`; numbers are produced by
`src/animation/benchmarks.zig` (`zig build bench-animation`).

## Context

The control-plane suites (`bench`, `bench-context`, `bench-core`, `bench-text`)
and the scene data-plane suite cover layout, dispatch, geometry, text, and the
scene→batch→frame path. The animation engine — which runs on every animating
window, every frame — was unbenched until now.

`spring.zig`'s header makes two explicit back-of-envelope claims (CLAUDE.md §7):

> Per-frame cost per active spring: one RK4 step = ~20 multiply-adds … At-rest
> springs cost one branch (early return in `tickSpring`). Zero physics.

`bench-animation` turns both halves of that claim into measured numbers, and
separates the **physics** cost (the RK4 step) from the **dispatch** cost (the
hash-map lookup + tick funnel the store walks each frame).

**Scope.** The store ticks via `tickSpring`, whose `dt` comes from the monotonic
`awake` clock. A benchmark frame completes well under one millisecond, so the
clock-derived `dt` rounds toward zero and the store path measures lookup +
dispatch overhead, not RK4 work. That separation is deliberate (CLAUDE.md §8,
control vs data plane): the RK4 cost is isolated in the Spring-step group with a
fixed `dt`, the dispatch cost in the Store-frame group.

---

## The suite

Run: `zig build bench-animation` (add `-Dbench-json-dir=<dir>` to capture JSON).
Validate (Debug, assertions live): the `validate:` tests in
`src/animation/benchmarks.zig` run under `zig build test` — they check that the
physics converges, that the at-rest tick leaves state untouched, and the
**steady-state zero-allocation invariant** via a counting allocator.

| Group | What it times | Reports |
| --- | --- | --- |
| Spring step | `stepSpring` RK4 integration at a fixed 1/60 s `dt` | ns / spring (physics) |
| Spring tick | `tickSpring` on settled springs (the early return) | ns / spring (at-rest) |
| Store frame (springs) | `beginFrame → springById×N → endFrame` | whole-frame µs vs budget |
| Store frame (motions) | the same cycle via `springMotionById` | whole-frame µs vs budget |

All groups collect p50/p99; the regression gate (`bench-compare`) classifies on
the best-of-N minimum.

---

## Results (macOS arm64, M-series, `ReleaseFast`)

These are the shape of the curve, not acceptance criteria.

### Spring step vs at-rest tick — "at-rest ≈ free" confirmed

| Test | Ops | ns/op | p99 |
| --- | --- | --- | --- |
| spring_step_256 | 256 | 9.86 | 17.25 |
| spring_step_1k | 1024 | 8.43 | 14.69 |
| spring_tick_atrest_256 | 256 | 1.09 | 1.14 |
| spring_tick_atrest_1k | 1024 | 1.21 | 1.46 |

The headline design claim holds. A full RK4 step costs **~8–10 ns/spring** —
four acceleration evaluations and a weighted average, exactly the ~20
multiply-adds `spring.zig` budgeted. An at-rest `tickSpring` costs **~1.1
ns/spring**: it reads `state.at_rest`, fills a handle, and returns. That is the
**~8× gap** that makes the design work — a window can register dozens of springs
and pay almost nothing for the ones sitting at rest, which is the overwhelmingly
common case (a toggle that settled three frames ago).

This is why the wake-on-target-change logic in `store.zig` (`springById`) and
`motion.zig` (`tickSpringMotion`) matters so much: it is the gate that keeps a
spring on the 1.1 ns path until something actually moves it.

### Store frame — per-frame dispatch is a rounding error

| Test | Springs | Avg/frame | p99/frame | % 60 Hz | % 120 Hz |
| --- | --- | --- | --- | --- | --- |
| frame_springs_16 | 16 | 0.15 µs | 0.17 µs | 0.00% | 0.00% |
| frame_springs_64 | 64 | 0.91 µs | 0.96 µs | 0.01% | 0.01% |
| frame_springs_256 | 256 | 5.99 µs | 6.63 µs | 0.04% | 0.07% |
| frame_spring_motions_64 | 64 | 0.98 µs | 1.00 µs | 0.01% | 0.01% |
| frame_spring_motions_256 | 256 | 6.19 µs | 10.83 µs | 0.04% | 0.07% |

Polling 256 springs through the store — `beginFrame`, 256 hash-map `getOrPut`s,
256 ticks, `endFrame` — is **~6 µs, 0.04% of the 60 Hz budget**. Per-spring
dispatch rises from ~9 ns (16 springs) to ~23 ns (256 springs) as the
`AutoArrayHashMapUnmanaged` working set spills out of L1, but even the 256-spring
frame is invisible next to layout, text, and GPU submission. Spring-motions track
the springs they wrap, with a slightly fatter tail (the extra `tickSpringMotion`
phase-derivation branch).

The **steady-state zero-allocation invariant passes**: after the pools grow to
hold every registered spring/motion during warmup, a frame's `getOrPut` on
existing keys never touches the heap (CLAUDE.md §2). This is gated in the
validate tests with a counting allocator.

### Back-of-envelope: a fully-active frame

The store frame measures idle dispatch; the physics is the Spring-step group.
A worst-case frame where **all 256 springs are in flight** is the sum:

```
6 µs (dispatch) + 256 × ~9 ns (RK4) ≈ 6 µs + 2.3 µs ≈ 8.3 µs
```

— still **~0.05%** of the 60 Hz budget. There is no realistic UI spring count
that makes the animation tick a frame-budget concern; the cost lives entirely in
what the springs *drive* (relayout, repaint), not in the springs themselves.

---

## External validation

The numbers were sanity-checked against the lineage gooey's animation model
draws from. These are structural cross-checks, not absolute-number comparisons.

### Interruptible springs (Framer Motion / react-spring / Apple)

gooey's spring is **declarative and interruptible**: you set the target every
frame, and the spring redirects from its current position and velocity without a
restart (`SpringState` carries `position` + `velocity`, `springById` only
updates `target`). That is the same model Framer Motion and react-spring
popularized for the web, and that Apple's `CASpringAnimation` / SwiftUI
`.spring()` use natively. The "preserve velocity on target change" behaviour is
the defining property of that family, and the at-rest-is-free result is what
makes it cheap enough to apply per-frame to many elements.

### RK4 over Euler

`spring.zig` integrates with 4th-order Runge–Kutta rather than explicit Euler.
The rationale (documented in the file and confirmed by the
`rk4 is stable at large timestep` test) is the standard numerical-methods
result: explicit Euler gains energy and oscillates or diverges at stiff
spring constants and large/dropped-frame timesteps, while RK4 stays stable for
the stiffness/damping range UIs use at one step per frame. The measured ~9 ns
for four acceleration evaluations is the price of that stability, and it is
negligible.

### Animate-only-while-active scheduling

The design only does physics work for springs that are not at rest, and
`AnimationStore.hasActiveAnimations()` lets the window skip scheduling a frame
when nothing is in flight. This mirrors the general
`requestAnimationFrame`-while-animating pattern (and GPUI/Zed's frame scheduling,
where a frame is only driven when something needs to change). The 1.1 ns at-rest
tick is what makes "poll every registered spring every frame to see if it woke"
affordable, so the scheduler can stay simple.

> Caveat: cross-framework figures are not directly comparable (different
> languages, integrators, and hardware). The robust takeaways are the
> structural ones: the ~8× at-rest/in-flight gap, the negligible store-dispatch
> cost, and the passing zero-allocation gate.

---

## Findings

1. **The at-rest fast path is real and load-bearing.** 1.1 ns vs ~9 ns is the
   single most important number here: it validates registering many springs and
   polling them unconditionally each frame. Any future refactor that adds work
   to the at-rest branch of `tickSpring` (or that forgets the wake-gate and
   leaves springs spuriously in-flight) would erase that margin — the
   `spring_tick_atrest_*` entries gate against exactly that.
2. **Dispatch is the cost, and it is tiny.** Per-spring store cost (~9→23 ns) is
   dominated by the hash-map lookup, not physics. If a profile ever shows the
   animation tick on a frame budget, the lever is the lookup (the pools are
   `AutoArrayHashMapUnmanaged` keyed by `u32`), not the integrator.
3. **No regressions to chase yet.** Unlike the scene suite's sort hot spot,
   nothing here prescribes a fix — the suite's value is locking in the at-rest
   margin and the zero-allocation guarantee so they can't silently regress.

---

## References

- Source: `src/animation/benchmarks.zig`, `src/animation/spring.zig`,
  `src/animation/motion.zig`, `src/animation/store.zig`
- Framer Motion — spring transitions (interruptible, velocity-preserving) —
  <https://www.framer.com/motion/transition/>
- react-spring — spring physics for UI — <https://www.react-spring.dev/>
- Apple — `CASpringAnimation` —
  <https://developer.apple.com/documentation/quartzcore/caspringanimation>
- Scandurra, A. *Leveraging Rust and the GPU to render user interfaces at
  120 FPS* (GPUI), Zed, 2023 — <https://zed.dev/blog/videogame>
- Baselines + regression workflow: `docs/benchmarks/README.md`
