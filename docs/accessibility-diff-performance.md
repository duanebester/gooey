# Accessibility Diff Performance

Benchmark notes and design analysis for the per-frame accessibility diff
(`src/accessibility/tree.zig` + `fingerprint.zig`). Companion to
`scene-data-plane-performance.md`; numbers are produced by
`src/accessibility/benchmarks.zig` (`zig build bench-accessibility`).

## Context

Immediate mode rebuilds the UI every frame, but platform accessibility APIs
expect **stable object identity** — VoiceOver tracks focus by object pointer,
AT-SPI2 by stable D-Bus path. `accessibility/` bridges that gap by rebuilding a
parallel a11y tree each frame and diffing it against the previous frame: each
element gets a content-derived `Fingerprint` for cross-frame identity, and
`endFrame` computes the **dirty** set (content changed or new) and the
**removed** set (gone this frame) that the platform bridge syncs.

That rebuild-and-diff runs every frame a window is visible, so it is a per-frame
cost on the critical path. Nothing benched it until now. This suite mirrors the
scene suite's frame-e2e group directly: a whole-frame µs number against the
budget is the only thing that answers "does the a11y diff fit the frame?".

**Scope.** The tree is static-allocation end to end (`constants.MAX_ELEMENTS`
fixed arrays, a 4096-bucket open-addressing `FingerprintMap`), so there is no
per-frame allocator churn to gate — the only heap touch is the one-time `Tree`
allocation (~350 KiB, heap-allocated per CLAUDE.md §14). The platform bridge sync
itself (NSAccessibility / AT-SPI2 / ARIA) needs a live screen reader and cannot
run headless; this measures the headless diff that produces the sync sets.

---

## The suite

Run: `zig build bench-accessibility` (add `-Dbench-json-dir=<dir>` for JSON).
Validate (Debug, assertions live): the `validate:` tests run under `zig build
test` — they assert a stable rebuild reports zero dirty after frame 1, and that
content churn marks exactly the changed elements dirty (and zero removed).

| Group | What it times | Reports |
| --- | --- | --- |
| Fingerprint | `fingerprint.compute` over N calls | ns / fingerprint |
| Frame diff (stable) | `beginFrame → pushElement×N → endFrame`, no churn | whole-frame µs vs budget |
| Frame diff (churn) | same, with a fraction changing content each frame | whole-frame µs vs budget |

All groups collect p50/p99; the gate classifies on the best-of-N minimum.

---

## Results (macOS arm64, M-series, `ReleaseFast`)

These are the shape of the curve, not acceptance criteria.

### Fingerprint — ~1.4 ns, parent contribution is free

| Test | Ops | ns/op | p99 |
| --- | --- | --- | --- |
| fingerprint_flat_4k | 4000 | 1.43 | 1.69 |
| fingerprint_parented_4k | 4000 | 1.44 | 3.29 |

`fingerprint.compute` is a Wyhash over the element name plus a few bit-packs into
a `u64` — **~1.4 ns**. Folding in a parent fingerprint (two XORs and a shift) is
free within timer resolution. This is the per-element identity primitive; the
frame diff calls it once per element during `pushElement`.

### Frame diff — flat per-element cost, comfortably under budget

| Test | Elements | Avg/frame | p99/frame | % 60 Hz | % 120 Hz | ns/element |
| --- | --- | --- | --- | --- | --- | --- |
| frame_stable_64 | 65 | 8.29 µs | 16.38 µs | 0.05% | 0.10% | 127 |
| frame_stable_256 | 257 | 31.43 µs | 43.29 µs | 0.19% | 0.38% | 122 |
| frame_stable_1000 | 1001 | 128.14 µs | 153.92 µs | 0.77% | 1.54% | 128 |
| frame_churn_256 | 257 | 32.03 µs | 45.79 µs | 0.19% | 0.38% | 125 |
| frame_churn_1000 | 1001 | 129.39 µs | 156.58 µs | 0.78% | 1.55% | 129 |

Two things stand out:

1. **Per-element cost is flat at ~122–129 ns from 64 to 1000 elements.** That is
   the headline: the whole diff is **O(n), not O(n²)**. It is what the
   `FingerprintMap` buys — `computeDirtyElements`/`computeRemovedElements` do
   O(1) hash lookups instead of the O(n) scans the `tree.zig` comments call out
   ("Uses hash map for O(n) total instead of O(n²)"). A 1000-element tree — well
   above the 200–500 a complex UI runs (`constants.zig`) — is **~128 µs, 0.77% of
   the 60 Hz budget.**
2. **Churn is nearly free on top of the rebuild.** Flipping the content of a
   fraction of live `.status` elements each frame (driving the dirty-detection +
   auto-announce path) adds **~1 ns/element** over the stable rebuild (129 vs
   128 µs at 1000). The frame cost is dominated by the *unconditional*
   per-element work — fingerprint, content hash, map insert/lookup — not by
   marking the handful that changed.

Tails are reasonable (p99 ≈ 1.2–2× avg); the 64-element p99 is the noisiest, as
expected for the shortest-running entry.

---

## Where the ~128 ns/element goes (and a latent halving)

Fingerprint is only ~1.4 ns of the ~128 ns/element, so the per-element cost is
dominated by the rest of the cycle: `pushElement` (element init + one
`FingerprintMap.insert`), the `endFrame` dirty pass (one `FingerprintMap.find` +
a `contentHash`), and the `beginFrame` snapshot (one `contentHash` +
`FingerprintMap.insert` to build the previous-frame map).

A latent finding falls out of that breakdown: **`contentHash` is computed twice
per element per frame.** `endFrame` hashes each current element in
`computeDirtyElements`; the next frame's `beginFrame` hashes those same elements
again to fill `prev_hashes` for the snapshot. The hash is a Wyhash over name +
value + description + state + numeric fields — not free at ~tens of ns.

**Prescription (when warranted):** store the hash `endFrame` already computes on
the `Element` (a `content_hash: u32` field), and have `beginFrame` read it from
the previous-frame elements instead of recomputing. That removes one of the two
hashes per element per frame. The win is partial (the hash is a fraction of the
128 ns), and at 0.77% of budget for 1000 elements there is no pressure to take
it today — but `frame_stable_1000` is the entry that would show the improvement
if a UI ever pushes element counts high enough to care.

---

## External validation

- **Rebuild-and-diff for retained identity.** Computing a content fingerprint so
  an immediate-mode tree can present stable identity to a retained platform API
  is the documented approach in `fingerprint.zig` (VoiceOver object identity,
  AT-SPI2 D-Bus paths). The same "rebuild every frame, reconcile against last
  frame" model is what Dear ImGui and React's reconciler use; here the
  reconciliation key is the semantic fingerprint rather than a React `key` or an
  ImGui ID stack.
- **O(n) diff via a hash map.** The flat ~128 ns/element curve is the empirical
  confirmation of the `FingerprintMap` optimization the `tree.zig` comments
  describe — without it, `computeDirtyElements` and `computeRemovedElements`
  would be O(n²) and the per-element cost would climb with element count instead
  of staying flat. The benchmark is what would catch a regression back to the
  scan.
- **Frame budget.** Same 16.67 ms (60 Hz) / 8.33 ms (120 Hz) budget as the scene
  suite. A realistic 200–500-element UI diffs in ~25–64 µs (≤0.4% of 60 Hz), so
  the a11y diff — like scene assembly — is not where the frame budget goes.

> Caveat: these are headless diff numbers on M-series silicon. The platform
> bridge sync (IPC to the screen reader) is a separate, unmeasured cost that
> only the dirty/removed *sets* feed; keeping those sets small (the diff's job)
> is what keeps that sync cheap.

---

## Findings

1. **The diff fits the frame with room to spare.** 1000 elements at 0.77% of the
   60 Hz budget, flat per-element — the `FingerprintMap` makes the diff O(n) and
   that is the property worth protecting.
2. **Churn is cheap.** Content changes cost ~1 ns/element over the rebuild, so a
   chatty live region or a list whose values tick every frame is not a concern.
3. **One latent halving exists** (cache `contentHash` across the
   endFrame→beginFrame boundary) but is not worth taking at current element
   counts — recorded here so `frame_stable_1000` can size it if that changes.

---

## References

- Source: `src/accessibility/benchmarks.zig`, `src/accessibility/tree.zig`,
  `src/accessibility/fingerprint.zig`, `src/accessibility/element.zig`,
  `src/accessibility/constants.zig`
- Accessibility architecture overview: `docs/accessibility.md`
- Dear ImGui — *About the IMGUI paradigm* —
  <https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm>
- Baselines + regression workflow: `docs/benchmarks/README.md`
