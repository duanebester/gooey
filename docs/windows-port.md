# Windows Port

## Status

`gooey.App` examples run on Windows: a Win32 window, DirectWrite text, WIC images, the
software SVG rasterizer, and the shared Vulkan renderer. Verified on an Intel UHD 620 at
150% scale. The [checklist](#win32-checklist) has what remains.

```sh
zig build run-showcase       # a gooey.App example (others listed in addWindowsBuilds)
zig build run-windows-demo   # the platform-layer demo, no text
zig build test-windows       # backend, DirectWrite, WIC, and SVG atlas tests
zig build typecheck-windows  # analyze the backend and showcase for x86_64-windows
```

Toolchain: Zig 0.17.0. Scope: 64-bit Windows only. `vulkan.zig` declares every handle,
dispatchable or not, as a nullable pointer, which matches the C ABI only on 64-bit targets,
so the backend and the COM bindings assert `@sizeOf(usize) == 8` at comptime.

If freshly linked binaries come out as 0-byte files that fail with `AccessDenied` or
`InvalidExe`, antivirus is quarantining them: exclude `.zig-cache` and `zig-out`.

## Approach

Vulkan first, not DirectX. After the surface split no Vulkan renderer file names a window
system except the surface implementation, so `VK_KHR_win32_surface` brings analytic AA,
fixed atlases, the upload journal, and the `ResourceLimits` budgets with no renderer work,
and phase 5 migrates one renderer for both Linux and Windows. DirectX comes later, if
needed, written straight against the phase 5 `Renderer` contract.

The real work is the Win32 half: windows and the message loop, input, IME, DPI, clipboard,
file dialogs, cursors, accessibility (UI Automation), and frame pacing on a render thread
(core contract, rule 1 and approved decision 5).

## Staying compatible with 0.4.0

| Layer | 0.4.0 work | Touches a Windows backend? |
| --- | --- | --- |
| core, ui, layout, scene, components | Rewritten in phases 3–6 | No. Stay out of these dirs. |
| `PlatformWindow` ⇄ framework | Phase 4 | Yes: seam 1, callbacks → `EventQueue` |
| Renderer entry, `render(scene)` | Phase 5 | Yes: seam 2, `Scene` → `PackedFrame` |
| Shaders, pipelines, atlases, `vk_mesh` | Stable | No. Reuse freely. |
| `ResourceLimits`, upload journal | Stable | No. Honour them. |

- **Seam 1 (phase 4).** Windows stop calling `on_input` and `on_render`; they push events
  into a bounded `EventQueue`, answer a read-only `Query` (IME caret rect, hit test), and
  signal ticks (`docs/v0.4.0-core-contract.md`, section 9). Every input message already
  goes through `Translator.translate` and is delivered by `Window.handleInput`, so phase 4
  changes that one call.
- **Seam 2 (phase 5).** The renderer draws a `PackedFrame` instead of the 0.3.1 `Scene`.
  The window draws only through `VulkanRenderer.render(scene)`, so phase 5 swaps that one
  entry.
- **Shared edits.** Keep them to one `.windows` arm per dispatcher: `platform/mod.zig`,
  `linux/vk_surface.zig`, `text/mod.zig`, `text_system.zig`, `text/cache.zig`,
  `image/loader.zig`, and the Windows functions in `build.zig`. Everything else lives in
  `src/platform/windows/` or a backend directory.
- **Boundary.** The Windows `mod.zig` pins `contract.verifyBackend(@This())`, so every
  contract change in 0.4.0 is a compile error naming the declaration.
- **Separate PRs.** Moving the Vulkan renderer out of `src/platform/linux/` and renaming
  `svg/backends/cairo.zig` are behaviour-neutral moves; keep them out of feature work.

## What has landed

### Vulkan surface

Window-system code in the Vulkan renderer sits behind one interface, chosen by
`builtin.os.tag` in `src/platform/linux/vk_surface.zig`, which pins it with
`contract.verifyConst` and `contract.verifyFn`:

```zig
pub const instance_extension_name: [*:0]const u8;
pub fn create(self: *const Self, instance: vk.Instance) !vk.Surface;
pub fn swapchainDestroyBegin(self: *const Self) void;
pub fn swapchainDestroyEnd(self: *const Self) void;
```

- `create` returns a non-null surface. The renderer owns it and destroys it with
  `vkDestroySurfaceKHR`, the same call for every window system.
- The destroy brackets run after the device is idle. Wayland flushes and roundtrips there;
  Win32 has nothing to synchronize, so `Win32Surface` only asserts its handle.
- `Win32Surface` (`src/platform/windows/vk_surface_win32.zig`) borrows the `HINSTANCE` and
  `HWND`. It is 16 bytes, so it is passed by value. `VkWin32SurfaceCreateInfoKHR` and
  `vkCreateWin32SurfaceKHR` are declared there, so the shared bindings are unchanged.

**Linking without the SDK.** GPU drivers install only `System32\vulkan-1.dll`, not an
import library. `build.zig` generates `vulkan-1.lib` from `src/platform/windows/vulkan-1.def`
with the bundled `zig dlltool -m i386:x86-64`. The `.def` lists the `pub extern fn vk*`
declarations in `linux/vulkan.zig`, minus `vkCreateWaylandSurfaceKHR`, plus
`vkCreateWin32SurfaceKHR`; a binding missing from it is a link error, so update it with
the bindings. Validation layers ship with the SDK, so without it Debug builds log
`VK_LAYER_KHRONOS_validation not available` and run without them.

### Window and platform

| File | Role |
| --- | --- |
| `src/platform/windows/win32.zig` | Hand-written `kernel32`/`user32` bindings, layouts pinned |
| `src/platform/windows/input.zig` | `Translator.translate`: one `WM_*` → one Gooey event |
| `src/platform/windows/platform.zig` | `WindowsPlatform`: window class, cursors, message loop |
| `src/platform/windows/window.zig` | `Window` and `windowProc`: `HWND`, renderer, contract |
| `src/platform/windows/mod.zig` | Backend namespace; `contract.verifyBackend`, 64-bit check |
| `src/windows_tests.zig` | Test root (in `src/` so it can import across subsystems) |
| `src/examples/windows_demo.zig` | Platform-layer demo: quads, animation, input logging |

- **Loop turn.** Each turn of `run` does bounded work: the owner's hook, at most
  `message_batch_max` (256) messages, timed-redraw deadlines, then at most one frame per
  open window. It sleeps in `MsgWaitForMultipleObjectsEx` until the next message, due
  frame, or deadline, 16 ms at most.
- **Pacing.** The swapchain prefers mailbox presentation, which never blocks, so a 60 Hz
  cap (`frame_period_ns_min`) keeps an animating window from saturating the GPU.
  Rendering is otherwise on demand.
- **Live resize.** Dragging an edge runs a modal loop inside `DefWindowProcW`, so
  `WM_PAINT` renders while the platform loop is blocked. Timed redraws do not fire then.
- **DPI.** Per-monitor v2. `size` is the client area in device pixels divided by
  `dpi / 96`. `WM_DPICHANGED` adopts the new scale and suggested rectangle; a window that
  opens on a monitor whose DPI differs from the system DPI is resized once.
- **Close.** `WM_CLOSE` runs the veto, records the close, and hides the window. The `HWND`
  is destroyed in `deinit`, never from inside its own dispatch.
- **Unimplemented features** (IME, clipboard, file dialogs, dark title bars) are reported
  as unavailable in `capabilities`, not faked.
- `platform/mod.zig` keys `DisplayLink` and the `macos` namespace on `is_macos`, not "not
  web and not Linux", which would select macOS code on Windows.

### Text (DirectWrite)

DirectWrite ships with Windows, so it needs no package (CLAUDE.md section 12). It covers
discovery, shaping, and rasterization without Direct2D or GDI. Requires Windows 8.1
(`IDWriteFactory2`).

| File | Role |
| --- | --- |
| `src/text/backends/directwrite/bindings.zig` | Hand-written COM bindings, slots pinned |
| `src/text/backends/directwrite/face.zig` | `DirectWriteFace`: discovery, metrics, raster |
| `src/text/backends/directwrite/shaper.zig` | `DirectWriteShaper`: script runs, clusters |
| `src/text/backends/directwrite/tests.zig` | Tests against the system's DirectWrite |

- **Bindings.** COM methods are found by vtable slot, so every vtable lists every slot in
  header order, with `Slot` placeholders for methods never called. A comptime block pins
  the slot of every called method and every structure's 64-bit layout. `extern "dwrite"`
  links through Zig's bundled MinGW import library. The WIC bindings follow the same rules.
- **Discovery.** A family resolves in the system collection; simulated faces are skipped
  and `font_match.select` picks by the CSS rule. Generic names map to Segoe UI, Consolas,
  and Times New Roman. A missing family renders as Segoe UI with a warning.
- **Units.** One font size unit is one DIP, as in CoreText. (The FreeType backend sizes at
  96 DPI, so Linux text is 4/3 larger; that is a Linux inconsistency.)
- **Shaping.** `AnalyzeScript` itemizes through an analysis source and sink the shaper
  implements over its own buffers; each script run goes through `GetGlyphs` and
  `GetGlyphPlacements`. Scratch is inline and fixed: at most 2,048 UTF-16 units, 3,088
  glyphs, and 256 script runs per call, failing with `TextTooLong` or `TooManyScriptRuns`.
  The returned glyph slice is heap-allocated because the shared `shape` contract requires
  it.
- **Rasterization.** `CreateGlyphRunAnalysis` with grayscale antialiasing, symmetric
  natural rendering, and grid fitting disabled, so outlines follow the cache's subpixel
  origin. A glyph over `MAX_GLYPH_SIZE` fails with `GlyphTooLarge` rather than cropping.
- **Coordinates.** The subpixel shift passed to `renderGlyphSubpixel` is in device pixels,
  and `render.zig` adds `y_offset` to a y-down baseline, so DirectWrite's upward
  `ascenderOffset` is negated. (The FreeType backend scales the shift a second time.)

### Images (WIC)

WIC ships with Windows, so it needs no package. `zig build run-images` shows every `Image`
mode with correct alpha.

| File | Role |
| --- | --- |
| `src/image/backends/wic/bindings.zig` | Hand-written WIC and COM bindings, slots pinned |
| `src/image/backends/wic/decoder.zig` | `loadFromMemory`: the image loader backend |
| `src/image/backends/wic/tests.zig` | Tests against the system's WIC |

- **Formats.** WIC sniffs the container: PNG, JPEG, GIF, BMP, TIFF, and ICO everywhere,
  WebP and HEIF where their system codecs are installed. A multi-frame image yields its
  first frame; EXIF orientation and color profiles are not applied, as on CoreGraphics.
- **Pixels.** The frame converts straight to `GUID_WICPixelFormat32bppRGBA`, the `.rgba`
  layout with straight alpha, so there is no swizzle or unpremultiply pass.
- **COM.** URL images decode on `Io.Group` worker threads, and WIC needs COM on the calling
  thread. Each call enters COM as multithreaded and balances the entry; a thread already
  in an STA (`RPC_E_CHANGED_MODE`) or MTA (`S_FALSE`) keeps its model.
- **Bounds.** Each side is at most `image_side_max` (16,384), so a frame fits WIC's 32-bit
  buffer size: at most 1 GiB transient per decode, checked before allocating. The buffer
  comes from the caller's allocator because the shared `DecodedImage` contract requires it.
- **Errors.** Codecs probe the header before claiming data, so an invalid PNG header is
  `InvalidFormat`. WIC reports success for a PNG truncated or corrupt inside its pixel
  data, so the buffer is zeroed first and undecoded rows are transparent black.

### SVG (software rasterizer)

`src/svg/rasterizer.zig` selects `backends/cairo.zig` for Windows as well as Linux. Despite
its name, that backend is a pure-Zig scanline rasterizer with no `extern` declarations,
built on the parser in `src/svg/path.zig`; it needs no package and no Direct2D. Its output
is the mask the shaders expect: R is fill alpha, G is stroke alpha, A is their maximum.
`zig build run-lucide-demo` draws all 1,669 Lucide icons.

- **Allocation.** The parser and flattener use `std.ArrayList`, and the backend allocates
  a stroke buffer, so `SvgAtlas` used to pass them the general-purpose allocator on every
  cache miss. It now reserves `raster_scratch` at init and hands the rasterizer a
  `FixedBufferAllocator` over it, reset per rasterization. This applies on every platform.
- **Budget.** `SvgAtlas.rasterScratchBytes(icon_size_max)` is one RGBA icon for the stroke
  buffer, 2,048 B per pixel of side for geometry, and 32 KiB: 800 KiB at the 256 px
  ceiling. The heaviest Lucide icon (`loader_pinwheel`, fill and stroke) needs 445,532 B
  at 256 px, and a test pins it below two thirds of the reservation. Exhaustion panics
  naming the pool, capacity, path length, size, and frame.
- **Quality.** Fill is 4× vertical supersampling with exact horizontal coverage, even-odd;
  stroke is a distance-to-segment pass with round joins and caps. Lucide at 150% looks
  correct. Not yet compared side by side with the CoreGraphics output; nonzero winding,
  miter joins, and butt caps are not implemented.

**How GPUI does it.** GPUI (Zed) has no Windows-specific SVG path. From memory of
`crates/gpui/src/svg_renderer.rs`, not checked against current Zed source: `usvg` parses
the document, `resvg` rasterizes it on the CPU into a `tiny-skia` pixmap, and icons keep
only the alpha channel, stored in the sprite atlas as a one-channel mask the shader tints.
The DirectX renderer samples that atlas like Metal and Vulkan do; neither Direct2D nor WIC
is involved. Gooey cannot copy this directly: resvg and tiny-skia are third-party packages
(CLAUDE.md section 12).

Gooey's route is the same shape, a CPU rasterizer feeding a mask atlas, with its own
rasterizer in place of resvg.

**Remaining debt.** Each item is its own commit or PR, kept out of feature work.

- **Recursive flattening.** `CubicBez.flattenRecursive` and
  `QuadraticBez.flattenRecursive` in `src/svg/path.zig` split curves recursively to depth
  16 (CLAUDE.md section 6). The stack is not the risk; the work bound is: levels 0–16 can
  all split, so one curve may emit 2^17 = 131,072 points, about 1 MiB, which exhausts the
  800 KiB scratch and panics. Lucide stops after a few levels. Inferred from the code, not
  tested: a NaN coordinate fails `flatness <= tol_sq` at every level and reaches full depth.
  Fix: a fixed 17-entry explicit stack (push right, then left, to keep point order), a
  depth cap derived from the scratch budget and pinned by a comptime assertion, and
  rejection of non-finite coordinates before flattening. `path.zig` is shared with the
  CoreGraphics backend, so the change can move pixels on every platform.
- **Misnamed backend.** `src/svg/backends/cairo.zig` contains no Cairo; the name implies
  a libcairo dependency that section 12 would forbid. Rename it (for example to
  `software.zig`). The rename is behaviour-neutral but public: `gooey.svg.backends.cairo`
  in `src/svg/mod.zig`, `src/svg/rasterizer.zig`, and `src/testing/README.md` change.
- **Direct-access export.** `src/svg/mod.zig` exposes `backends.cairo` only when
  `builtin.os.tag == .linux`, so on Windows it is an empty struct although Windows uses
  that backend. Nothing in Gooey reads it. Add the `.windows` arm.
- **Line width.** `SvgKey.init`'s signature in `src/svg/atlas.zig` is 121 columns
  (section 25). It predates the port; a trailing comma lets `zig fmt` wrap it.

## Win32 checklist

Each item must honour `ResourceLimits` and the static-allocation rule (CLAUDE.md section 2):
no allocation after the initialization boundary, which on native platforms ends just before
the event loop.

- [x] Vulkan surface split and `Win32Surface`.
- [x] Backend skeleton, window class, window procedure, and message loop.
- [x] Input: one `WM_*` → Gooey event translation function (seam 1).
- [x] DPI awareness (per-monitor v2, `WM_DPICHANGED`).
- [x] Cursors (arrow, I-beam, hand via `WM_SETCURSOR`).
- [x] `build.zig` Windows targets and `typecheck-windows`.
- [x] Text (DirectWrite: discovery, shaping, grayscale rasterization).
- [x] Image decoding (WIC).
- [ ] CI: run `typecheck-windows` on Linux CI, modelled on `typecheck-linux`.
- [ ] Wire `root.zig`'s test block up for Windows; `test-windows` covers only the
      backends.
- [x] SVG rasterization (software rasterizer, fixed scratch arena).
- [ ] Text: font fallback (`IDWriteFontFallback::MapCharacters` can reuse the analysis
      source), bidi, color glyphs.
- [ ] IME (`WM_IME_*`, caret rect from the read-only query).
- [ ] Clipboard.
- [ ] File dialogs.
- [ ] Accessibility through UI Automation.
- [ ] Frame pacing on a render thread.
