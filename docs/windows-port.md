# Windows Port

## Status

Not started on Windows itself. One enabling change has landed on
`v0.4.0/vulkan-surface-split`: Vulkan surface creation is split out of the renderer (see
[What has landed](#what-has-landed)). There is no `src/platform/windows/` directory, no
Windows target in `build.zig`, and no `.windows` arm in `platform/mod.zig` yet.

Scope: 64-bit Windows only (`x86_64-windows`). 32-bit Windows is not supported. This
matters for the Vulkan bindings: `vulkan.zig` declares every handle, dispatchable or not, as
a nullable pointer, which matches the C ABI only on 64-bit targets. The Windows backend MUST
assert `@sizeOf(usize) == 8` at comptime so a 32-bit target fails with a clear message
rather than a silent ABI mismatch.

## Approach

Start with Vulkan on Windows, not DirectX.

- The Vulkan renderer is about 6k lines, and after the surface split no file in it names a
  window system except the surface implementation. Adding `VK_KHR_win32_surface` brings
  analytic AA, fixed atlases, the upload journal, and the `ResourceLimits` budgets with no
  renderer work.
- Phase 5 (Scene → `PackedFrame`) then migrates one Vulkan renderer for both Linux and
  Windows.
- DirectX comes later, if needed for GPUs or users without Vulkan. By then it is written
  straight against the phase 5 `Renderer` contract, with no 0.3.1 interface to port.

The real work is the Win32 half: windows and the message loop, input, IME, DPI, clipboard,
file dialogs, cursors, accessibility (UI Automation), and frame pacing on a render thread
(core contract, rule 1 and approved decision 5).

## What 0.4.0 changes, and where it reaches a backend

| Layer | 0.4.0 work | Touches a Windows backend? |
| --- | --- | --- |
| core, ui, layout, scene, components | Rewritten in phases 3–6 | No. Stay out of these dirs. |
| `PlatformWindow` ⇄ framework | Phase 4 | Yes: seam 1, callbacks → `EventQueue` |
| Renderer entry, `render(scene)` | Phase 5 | Yes: seam 2, `Scene` → `PackedFrame` |
| Shaders, pipelines, atlases, `vk_mesh` | Stable | No. Reuse freely. |
| `ResourceLimits`, upload journal | Stable | No. Honour them. |

### Seam 1: window events (phase 4)

Windows stop calling `on_input` and `on_render`. They push events into a bounded
`EventQueue`, answer a read-only `Query` (IME caret rect, hit test), and signal ticks
(`docs/v0.4.0-core-contract.md`, section 9).

To stay ready: translate every `WM_*` message into a Gooey input event in one function, and
deliver the result in one place. Phase 4 then changes one call, not the window procedure.

### Seam 2: renderer input (phase 5)

The renderer stops reading the 0.3.1 `Scene` and draws a `PackedFrame`: bounded instance
buffers plus a draw list. Until then the pack stage keeps producing the old `Scene`, so the
Vulkan renderer works unchanged on Windows in the meantime. Any Windows-only drawing code
MUST stay behind a single `drawScene(scene)`-style entry, as Vulkan's does, so phase 5 swaps
only that function.

## What has landed

### Vulkan surface split

The Vulkan renderer touched Wayland in three places: the instance extension it enabled, the
`VkSurfaceKHR` it created, and `wl_display` flush and roundtrip calls around swapchain
destruction. All three now sit behind one interface:

| File | Role |
| --- | --- |
| `src/platform/linux/vk_surface.zig` | `NativeSurface`, chosen by `builtin.os.tag`; `verify` |
| `src/platform/linux/vk_surface_wayland.zig` | `WaylandSurface`, the first implementation |
| `src/platform/linux/vk_instance.zig` | `createInstance(surface_extension_name)` |
| `src/platform/linux/vk_renderer.zig` | `initWithNativeSurface(native_surface, …)` |

`vk_surface.verify` pins the interface with `contract.verifyConst` and `contract.verifyFn`,
so drift fails to compile with a message naming the declaration. An implementation provides:

```zig
pub const instance_extension_name: [*:0]const u8;
pub fn create(self: *const Self, instance: vk.Instance) !vk.Surface;
pub fn swapchainDestroyBegin(self: *const Self) void;
pub fn swapchainDestroyEnd(self: *const Self) void;
```

- `create` returns a non-null surface. The renderer owns it from then on and destroys it with
  `vkDestroySurfaceKHR`, which is the same call for every window system.
- `swapchainDestroyBegin` and `swapchainDestroyEnd` bracket swapchain destruction after the
  device is idle. Wayland flushes and roundtrips there; Win32 has nothing to synchronize, so
  both are empty.

The renderer stores the value it was initialized with in `native_surface: ?NativeSurface`
and calls the brackets from `destroySwapchainResources`. It holds no other window-system
state.

The change is behaviour-neutral on Linux: same extensions, same calls in the same order.
It was verified with `zig build typecheck-linux` from a Windows host.

## Next: the Windows surface

The planned `Win32Surface`, written against the interface above. This is a sketch, not code
that exists:

```zig
// src/platform/windows/vk_surface_win32.zig
pub const Win32Surface = struct {
    hinstance: *anyopaque, // HINSTANCE, borrowed from the platform
    hwnd: *anyopaque, // HWND, borrowed from the window

    pub const instance_extension_name: [*:0]const u8 = "VK_KHR_win32_surface";

    pub fn create(self: *const Win32Surface, instance: vk.Instance) CreateError!vk.Surface;
    pub fn swapchainDestroyBegin(self: *const Win32Surface) void {}
    pub fn swapchainDestroyEnd(self: *const Win32Surface) void {}
};
```

- `create` fills `VkWin32SurfaceCreateInfoKHR` (`sType` 1000009000; 40 bytes on 64-bit) and
  calls `vkCreateWin32SurfaceKHR`. Declare both in the Windows file, not in `vulkan.zig`, so
  the Windows PR does not edit the shared bindings.
- `Win32Surface` is two pointers (16 bytes), so it is passed by value (CLAUDE.md section 13).
- Enable it with one arm in `vk_surface.zig`:
  `.windows => @import("../windows/vk_surface_win32.zig").Win32Surface`.

## Keeping the port from clashing with 0.4.0

Branch from `integration/v0.4.0`, not `main`. `main` lacks the profiles, fixed atlases, and
analytic AA a new backend must honour.

Keep shared edits to these places, so rebase conflicts stay small:

1. One `.windows` arm in `src/platform/mod.zig` (backend selection).
2. The Windows target in `build.zig`: link `vulkan-1` instead of `vulkan`, plus the Win32
   system libraries the backend needs.
3. One `.windows` arm in `src/platform/linux/vk_surface.zig`.

Everything else lives in `src/platform/windows/`. The Vulkan renderer files currently live
under `src/platform/linux/` and are imported from there. Moving them to a shared directory
is a separate, behaviour-neutral PR; do not fold it into the Windows work.

Let the compiler check the boundary: the Windows `mod.zig` pins
`contract.verifyBackend(@This())` as the other backends do, so every contract change in 0.4.0
shows up as a compile error naming the declaration.

Add a cheap CI check: a cross-compile type check for `-Dtarget=x86_64-windows` on Linux CI,
modelled on `typecheck-linux` in `build.zig`. It catches breakage without a Windows runner.

## Win32 checklist

Each item must honour `ResourceLimits` and the static-allocation rule (CLAUDE.md section 2):
no allocation after the initialization boundary, which on native platforms ends just before
the event loop.

- [x] Vulkan surface split (behaviour-neutral, Linux).
- [ ] `Win32Surface` and the `vk_surface.zig` arm.
- [ ] Backend skeleton: `src/platform/windows/mod.zig` with `Platform`, `PlatformWindow`,
      `drive_model`, and `contract.verifyBackend`.
- [ ] `build.zig` Windows target and the `x86_64-windows` type check in CI.
- [ ] Window class, window procedure, and the message loop.
- [ ] Input: one `WM_*` → Gooey event translation function (seam 1).
- [ ] IME (`WM_IME_*`, caret rect from the read-only query).
- [ ] DPI awareness (per-monitor v2, `WM_DPICHANGED`).
- [ ] Clipboard.
- [ ] File dialogs.
- [ ] Cursors.
- [ ] Accessibility through UI Automation.
- [ ] Frame pacing on a render thread.
