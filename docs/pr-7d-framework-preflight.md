# Sub-PR 7d-framework — Pre-Flight Plan

> Standalone pre-flight for the 7d-framework slice of
> [`cleanup-implementation-plan.md`](./cleanup-implementation-plan.md)
> PR 7. Kept in its own file because the main cleanup doc is
> auto-formatted on save and a 6000-line normalization pass
> would obscure the substantive change.

**Status:** ☑ landed on `cleanup/pr-7d-framework`. See
"Landing notes" section below for the deviation from the
original pre-flight scope (the framework-side-only plan
proved unworkable and absorbed the 7d-examples mechanical
sweep).

**Hard dependency for:** PR 9 Task 4 (the 39-example
`pub fn main(init: std.process.Init)` sweep). 9a / 9b / 9c
can land in parallel with 7d-framework if scheduled, but
9c (the bulk example sweep) cannot.

---

## TL;DR

Three signatures, one body delete, one default-value swap,
one unused-parameter discard.

- `src/runtime/runner.zig::runCx` — take `init: std.process.Init`
  as a trailing parameter; use `init.gpa` instead of the
  internal `DebugAllocator`; default `io` from `init.io`
  instead of the global single-threaded fallback.
- `src/app.zig::App.main` — take `init` and thread it
  through to `runCx`.
- `src/app.zig::WebApp.main` — take `init` for signature
  parity with the native arm; body stays no-op.

Plus two doc-block updates:

- `src/app.zig#L13-19` module-level example.
- `src/examples/ai_canvas.zig` (the one example already on
  the new shape with a workaround that 7d-framework
  retires).

**No new tests.** Existing 1103-test suite exercises every
integration path through `runCx`.

**No user-facing example sweep.** 38 examples stay on bare
`pub fn main()` until PR 9b/9c rewrites them as part of
the demoted-name migration.

---

## Why a separate PR (not folded into PR 9)

Three reasons, in order of weight:

1. **Bisect property.** PR 9 is the first PR in the
   cleanup that actually breaks the public API. Keeping
   the framework signature change separately revertable
   preserves the property every prior cleanup PR has
   honored: every commit in the 28-commit landing trail
   is independently revertable. A regression downstream
   wants to bisect to either *framework signature flipped*
   (7d-framework) or *examples got rewritten* (PR 9), not
   to a commit doing both.

2. **Write-scope discipline.** PR 9 already owns ~40
   files (39 examples + `root.zig` + `cx.zig`
   deprecated-forwarder deletion + `app.zig` doc-block +
   `build.zig` audit pin + `CHANGELOG.md`). Adding
   `src/runtime/runner.zig` into that scope conflates
   "framework runtime entry-point signature change" with
   "re-export hygiene + example sweep". They have
   orthogonal failure modes: the former breaks `io` /
   `gpa` lifetime; the latter breaks user-facing imports.

3. **`ai_canvas.zig` is already on the wrong shape.**
   `src/examples/ai_canvas.zig#L144` adopted
   `pub fn main(init: std.process.Init)` ahead of the
   framework and has to work around the gap:

   ```zig
   pub fn main(init: std.process.Init) !void {
       if (platform.is_wasm) unreachable;
       process_io = init.io;
       spawnReaderThread();
       return App.main();
   }
   ```

   It grabs `init.io` for its own use, then **discards
   `init.gpa`** and falls back to `App.main()` which
   internally constructs a `DebugAllocator`. 7d-framework
   fixes that structurally so PR 9 doesn't have to repeat
   the workaround 39 times.

---

## The three signatures

### 1. `src/runtime/runner.zig#L69-74` — `runCx`

Current:

```zig
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // ...
    const io = config.io orelse std.Io.Threaded.global_single_threaded.io();
```

Target:

```zig
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
    init: std.process.Init,
) !void {
    const allocator = init.gpa;
    // ...
    const io = config.io orelse init.io;
```

Specifically:

- Delete the two-line `var gpa:
  std.heap.DebugAllocator(.{}) = .init; defer _ =
  gpa.deinit();` block at L75-76.
- Replace `const allocator = gpa.allocator();` at L77
  with `const allocator = init.gpa;`.
- Flip L117 from `config.io orelse
  std.Io.Threaded.global_single_threaded.io()` to
  `config.io orelse init.io`. `CxConfig.io` stays
  optional (for callers that want to override the
  default), but `init.io` replaces the global
  single-threaded fallback.

### 2. `src/app.zig#L101-103` — native `App.main`

Current:

```zig
pub fn main() !void {
    try runCx(State, state, render, .{
        .title = if (@hasField(@TypeOf(config), "title")) config.title else "Window App",
        // ... ~30 lines of config field forwarding ...
    });
}
```

Target: flip to `pub fn main(init: std.process.Init) !void`
and add `, init` to the trailing argument of the
`runCx(State, state, render, .{...})` call. The giant
`.{}` config literal is untouched.

### 3. `src/app.zig#L455-458` — WASM `WebApp.main`

Current:

```zig
pub fn main() !void {
    // WASM initialization is driven by JavaScript calling the exported init().
    // This function exists only for API compatibility.
}
```

Target:

```zig
pub fn main(init: std.process.Init) !void {
    _ = init;
    // WASM initialization is driven by JavaScript calling the exported init().
    // This function exists only for API compatibility.
}
```

The body stays no-op (JS calls the `callconv(.c)` exports
directly), but the signature has to match the native arm
so `gooey.App(...)` returns a type with a single `main`
signature regardless of target.

---

## Doc-block updates landing in the same PR

- **`src/app.zig#L13-19`** — the module-level doc-block
  example reads
  `pub fn main() !void { try gooey.run(.{ ... }); }`. Update
  to
  `pub fn main(init: std.process.Init) !void { try gooey.run(init, .{ ... }); }`.
  This is the example the README and downstream docs
  quote.

- **`src/examples/ai_canvas.zig#L144-150`** — flip from
  "discard `init`, then call bare `App.main()`" to
  passing `init` through. This is the regression test
  for the framework change: if `ai_canvas` keeps working
  after 7d-framework, the framework wiring is right.

---

## Do-not-do list (keeps the PR ruthlessly small)

- Do **NOT** rename `runCx` to `run` — that's PR 9 Task 2's
  curated-core demotion. `gooey.run` is born in PR 9.

- Do **NOT** touch any example except `ai_canvas.zig`.
  The other 38 stay on bare `pub fn main()` until PR
  9b/9c rewrites them as part of the demoted-name sweep.

- Do **NOT** delete `WebApp` (the type) even though PR 9
  plans to make it private. That's a separate decision
  in PR 9 Task 2.

- Do **NOT** touch `src/runtime/multi_window_app.zig`
  unless its public entry point is on the same
  `pub fn main()` shape. Audit at PR-open time; the
  multi-window flow may already be on `init`-style. If it
  isn't, that's a separate sub-PR.

- Do **NOT** backfill tests for the signature change. The
  existing 1103-test suite runs through `runCx` for every
  integration test; if those pass, the signature change
  is wired right. New unit tests for `init.gpa` /
  `init.io` plumbing are bikeshed.

---

## Open question to resolve in the PR description (not in code)

`gooey.run(init, .{ ... })` keeps `init` as the first arg
of the curated-core `run` entry point in PR 9, but
`runCx(State, state, render, config, init)` puts `init`
last because the four preceding params are all
comptime/comptime-known and `init` is the only runtime
value.

Worth one sentence in the PR description spelling out the
asymmetry:

> `init` goes last on `runCx` because the four preceding
> params are comptime; the curated-core
> `gooey.run(init, .{...})` wrapper in PR 9 reorders to
> put `init` first to match every Zig 0.16
> `pub fn main(init)` example in the stdlib.

---

## Acceptance criteria

- `git --no-pager diff --stat` shows ≤ 4 files changed
  (`src/runtime/runner.zig`, `src/app.zig`,
  `src/examples/ai_canvas.zig`, the doc tick in
  `cleanup-implementation-plan.md`).

- `grep -n "DebugAllocator" src/runtime/runner.zig`
  returns nothing.

- `grep -n "global_single_threaded" src/runtime/runner.zig`
  returns nothing (other callers in `src/runtime/`
  retained).

- `zig build test --summary all` reports 1103/1103
  passing (no count change — pure plumbing, no new
  tests).

- `zig build install` produces every example binary (all
  39 still on bare `pub fn main()` aside from `ai_canvas`
  which moves to the new shape).

- Tracker row in
  [`cleanup-implementation-plan.md`](./cleanup-implementation-plan.md)
  L94 for PR 7 status flips to record
  `7d-framework: landed`; the `☐ 7d-framework` checkbox
  in the 7d sub-task list (around L1273) flips to `☑`.

---

## After 7d-framework lands

PR 9a (Task 2.5, module-side prep —
`platform.web.image_loader` move + duplicate stub kill +
`OnSelectHandler` re-export) is unblocked. 9a is also
small (≤ 3 files, no example touches), so the cadence
stays *small PRs landing fast* through the entire PR 9
sub-PR chain (9a / 9b / 9c / 9d / 9e / 9f). Same rhythm
that made PR 7c.3a-d and PR 8.4a-c land cleanly.

---

## Pre-flight reality checks (run before opening the PR)

```sh
# Confirm the three signature sites are still where this doc claims
grep -n "^pub fn runCx" src/runtime/runner.zig
grep -n "^pub fn main\|^        pub fn main" src/app.zig

# Confirm DebugAllocator is still in runner.zig (the body delete target)
grep -n "DebugAllocator" src/runtime/runner.zig

# Confirm ai_canvas.zig still has the workaround pattern
grep -n "process_io = init.io" src/examples/ai_canvas.zig

# Confirm multi_window_app.zig audit (the optional fourth signature)
grep -n "^pub fn main\|pub fn run" src/runtime/multi_window_app.zig
```

If any of these greps return surprising results (signature
moved, body already migrated, etc.), update this doc
before opening the PR — don't paper over the drift in the
commit message.


---

## Landing notes (PR 7d-framework)

**Status:** ☑ landed. `Build Summary: 9/9 steps succeeded;
1103/1103 tests passed` (no delta vs. PR 8.4c's 1103 —
this slice is pure plumbing, no new tests). `zig build
install` clean (71/71 binaries).

### What actually landed

The pre-flight's "framework-side only, no example sweep"
scope proved unworkable in the Zig 0.16 reality. The
diagnosis:

- `std.process.Init` is a *runtime-provided* value. There
  is no public constructor; the Zig start code populates
  it before calling `main`. Examples cannot construct it
  themselves.
- The framework signature change makes `App.main` require
  an `init` parameter (so the runner can use `init.gpa`
  instead of an in-place `DebugAllocator` and `init.io`
  instead of the global single-threaded fallback).
- Every example that calls `App.main()` from a bare
  `pub fn main() !void { return App.main(); }` therefore
  fails to compile the moment the framework signature
  flips — they have no `init` value to forward.

Three resolution paths were considered, in order:

1. **Make `App.main` accept an optional/defaulted `init`**
   (rejected — Zig has no default args; the workaround
   was to construct a fake `init` with `undefined` fields
   which would be a worse failure mode).
2. **Keep `App.main` no-arg by constructing `init`
   internally** (rejected — `std.process.Init`'s fields
   like `arena` and `environ_map` cannot be conjured
   without runtime support).
3. **Migrate the examples in the same PR** (chosen).
   A one-line mechanical change per example: change the
   signature to `pub fn main(init: std.process.Init)` and
   forward `init` to `App.main(init)` or as the trailing
   arg to `gooey.runCx(..., init)`.

The cleanup-implementation-plan.md already anticipated
this fold-up as PR 9 Task 4 (the "folded from 7d-examples"
sweep) — 7d-framework simply absorbed it one PR earlier
because the framework signature change couldn't land
without it.

### Scope summary

- `src/runtime/runner.zig` — `runCx` accepts `init` as
  trailing parameter; uses `init.gpa` instead of in-place
  `DebugAllocator`, falls back to `init.io` instead of
  `std.Io.Threaded.global_single_threaded.io()`.
- `src/app.zig` —
  - Native `App.main` flipped to
    `pub fn main(init: std.process.Init) !void`, forwards
    `init` as trailing arg to `runCx`.
  - WASM `WebApp.main` flipped to match the native arm's
    signature; body discards `init` (`_ = init;`) because
    WASM bootstrap is JS-driven.
  - Module-level doc-block example flipped to the new
    shape.
  - WASM `pub fn init() callconv(.c) void` renamed to
    `pub fn wasmInit()` to avoid shadowing the new `init`
    parameter on `WebApp.main`. The JS-visible export
    name stays `"init"` (the `@export` decl names the
    symbol independently of the Zig identifier).
- `src/examples/ai_canvas.zig` — `App.main()` →
  `App.main(init)` (drops the pre-7d workaround that
  read `init.io` and then discarded `init.gpa`).
- 35 other examples calling `App.main()` — mechanical
  one-line signature + forwarder change.
- 4 examples calling `gooey.runCx(...)` directly
  (`actions.zig`, `animation.zig`, `glass.zig`,
  `window_features.zig`) — signature change + `init`
  added as trailing arg to the `runCx` call.
- 4 examples without a `std` import (`layout.zig`,
  `select.zig`, `tooltip.zig`, `modal.zig`) — added
  `const std = @import("std");` so the new signature
  resolves.
- 2 examples (`linux_demo.zig`, `multi_window.zig`) that
  don't call `App.main` / `runCx` at all stayed on bare
  `pub fn main() !void` — that's one of the three valid
  Zig 0.16 main shapes and they construct their own
  allocator / io directly.

`git diff --stat` total: **39 files changed, 142
insertions, 87 deletions**. Much larger than the
pre-flight's "≤ 4 files" target — but that target was
based on the framework-side-only scope that proved
unworkable.

### Diff sanity grep (post-landing)

```
$ grep -n "DebugAllocator" src/runtime/runner.zig
72:/// previous in-place `DebugAllocator` is replaced with `init.gpa`,
88:    // throwaway `DebugAllocator` inside the runner. `init.gpa` is the
$ grep -n "global_single_threaded" src/runtime/runner.zig
260:        /// `std.Io.Threaded.global_single_threaded` fallback in favour
```

The remaining `DebugAllocator` / `global_single_threaded`
references in `runner.zig` are all in doc comments
explaining what was retired. The runtime construction
itself is gone.

### Why `wasmInit` rename instead of a parameter rename

The shadow conflict was between `pub fn init()` (the
WASM JS-callable export) and the new `init` parameter on
`WebApp.main`. Two fixes were possible:

- Rename the `init` *parameter* on `WebApp.main` to
  something like `process_init`. Asymmetric with the
  native arm and breaks the Zig 0.16 convention that the
  parameter is named `init`. Every Zig 0.16 example in
  the stdlib uses `init`, and `App.main`'s native arm
  also uses `init`.
- Rename the `init` *function* (the WASM export) to
  `wasmInit`. The JS-visible export name is controlled
  by `@export(...).name` independently of the Zig
  identifier, so the JS contract is preserved
  (`@export(&Self.wasmInit, .{ .name = "init" })`).

The second was chosen because (1) it preserves the
Zig 0.16 convention on `main`, (2) the rename is one
declaration site + one `@export` line, and (3) no
external code references `WebApp.init` directly
(verified via repo-wide grep).

### Open follow-ups

- PR 9 Task 4 (the 39-example `pub fn main(init)` sweep)
  is now ☑ done.
- The pre-flight's `gooey.run(init, .{...})` curated-core
  wrapper still lands in PR 9 Task 1 (the curated-7
  re-export). After PR 9 lands, examples can flip from
  `gooey.runCx(..., init)` and `App.main(init)` /
  `App(...).main(init)` to the cleaner `gooey.run(init,
  .{...})` shape. That migration is a PR 9 deliverable,
  not a 7d-framework one.
