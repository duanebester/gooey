# Platform interface and boundary design

## Status

Superseded by the 0.4 core (2026-11-14, v0.5.1). This document was written on 2026-09-15
against the 0.3.1 runtime, whose platform and window vtables, runners, and per-window
callbacks it set out to replace. The 0.4 migration replaced that runtime instead
(`docs/v0.4.0-core-contract.md`), so the boundary it proposed now exists in a different
form. What follows keeps the decisions, which still hold, and records where each phase of
the original plan ended up. Git history keeps the 0.3.1 analysis and the proposed
signatures.

## Decision summary

These decisions still hold; source comments cite them by number.

1. Compile-time backend selection remains Gooey's canonical platform abstraction.
2. `PlatformVTable` and `WindowVTable` should be removed unless an approved embedding use case
   requires runtime type erasure.
3. Tests should inject a backend at compile time rather than use platform vtables.
4. Platforms may have different host drive models, but must exchange the same bounded event and
   frame data with Gooey.
5. Platform services such as clipboard and file dialogs must be separate from window rendering.
6. Every runtime platform path must use storage reserved during initialization.
7. Unsupported operations, capacity exhaustion, and operating errors must be explicit.

## The boundary on the core

Each target has one core host, `src/platform/<target>/core_host.zig` (macOS, Linux on
Wayland, fbdev, Windows, and the web). A host opens the one window, pushes input into the
window's bounded `EventQueue`, answers synchronous platform questions through the read-only
`Query`, drives the tick, and hands each packed frame to its renderer (contract §5 and §9).
`gooey.App.main` picks the host at compile time; there is no runtime vtable (decisions 1
and 2).

- **Renderers** implement the §9 `Renderer` contract, checked with complete function types
  by `backend.verifyRenderer` (`src/core/backend.zig`, using `src/platform/contract.zig`):
  Metal, Vulkan, the Wayland shm and fbdev CPU renderers, WebGPU, and Direct3D 11.
- **Tests** run the same core on `TestBackend` with a `NullRenderer`
  (`src/testing/test_backend.zig`), selected at compile time (decision 3).
- **Drive models** differ only in who runs the render half of the tick: a render thread on
  macOS, Wayland, and Windows; the main thread right after the main half on fbdev and the
  web, where the browser's `requestAnimationFrame` drives both (contract decision 9). All
  of them exchange the same queue and packed frame (decision 4).

## Where each phase ended up

1. **Pin the current contract.** Done for 0.3.1, then replaced: the platform and window
   contracts left with the 0.3.1 runtime. `contract.zig` now pins the renderer contract and
   the Vulkan surface (`linux/vk_surface.zig`).
2. **Remove unused runtime interfaces.** Done; the vtables are gone.
3. **Normalize lifecycle and ownership.** Done on the core: `App` enters `running` after
   init, and the lifecycle guard panics on any allocation through Gooey's allocator after
   it (contract rule 2). The window registry still allocates once per window at init; with
   one window per app (contract decision 14) that is inside init.
4. **Bounded event batches.** Done as the core's `EventQueue` and `CompletionRing`
   (contract §5): every host pushes into the same bounded queue, pointer moves and scroll
   deltas coalesce, and any other overflow panics with the queue's name.
5. **A frame submission boundary.** Done as the packed frame and the `Renderer` contract
   (contract §9, v0.4.3). Every renderer draws the same `PackedFrame`; there is no scene
   handoff or atlas setter.
6. **Separate platform services.** Partly done; see below.
7. **Test and CI coverage.** `zig build test` runs `TestBackend` and the goldens on Linux
   and macOS in CI, and the macOS job also runs `typecheck-linux` and `typecheck-windows`.
   Still open: WASM contract tests and a browser integration runner.

## Phase 6: platform services

File dialogs are a service of their own (`FileDialogService`, `src/core/window.zig`): a
handler requests one through `Effects`, the tick opens it on the main thread, and the
outcome arrives on a later drain as `file_selected`, `cancelled`, or `failed` (contract
decision 11). The clipboard belongs to the text engines and has no public API (contract
decision 10).

Still open:

- **Path storage.** `PathPromptResult` (`src/platform/interface.zig`) still hands over
  slices with an allocator. The core passes the tick's reserved text scratch, so nothing
  allocates after init, but the type still reads as an ownership transfer. Bounded request
  slots would make that explicit.
- **Failure and cancellation on macOS.** An allocation failure in the AppKit dialog comes
  back as `cancelled` (`src/platform/macos/file_dialog.zig`), so decision 7 does not hold
  there yet.
- **The web** has no file dialogs (a known gap since 0.4.0).
