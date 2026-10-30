# Windows Port

## Status

`gooey.App` examples run on Windows: a Win32 window, DirectWrite text, WIC images, the
software SVG rasterizer, the system clipboard, native file dialogs, UI Automation
accessibility, and the shared Vulkan renderer. Verified on an Intel UHD 620 at 150% scale.
The [checklist](#win32-checklist) has what remains.

```sh
zig build run-showcase       # a gooey.App example (others listed in addWindowsBuilds)
zig build run-clipboard      # copy and paste through TextInput and TextArea
zig build run-file-dialog    # open, multi-select, folder, and save dialogs
zig build run-accessible-form # UI Automation: Narrator, NVDA, or Inspect
zig build run-windows-demo   # the platform-layer demo, no text
zig build test-windows       # backend, clipboard, dialogs, a11y, DirectWrite, WIC, SVG
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
  `image/loader.zig`, the clipboard selection in `widgets/text_input_state.zig` and
  `widgets/text_area_state.zig`, and the Windows functions in `build.zig`. Everything else
  lives in `src/platform/windows/` or a backend directory.
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
- **Unimplemented features** (IME, dark title bars) are reported as unavailable in
  `capabilities`, not faked.
- `platform/mod.zig` keys `DisplayLink` and the `macos` namespace on `is_macos`, not "not
  web and not Linux", which would select macOS code on Windows.

### Clipboard

`src/platform/windows/clipboard.zig` reads and writes `CF_UNICODETEXT` with the same
`getText(allocator)` and `setText(text)` API as the Linux and macOS clipboards, so the text
widgets select it with one `.windows` arm.

- **Owner.** `SetClipboardData` fails without an owner window, so `WindowsPlatform` creates
  a message-only `STATIC` window in `initInPlace` and destroys it in `deinit`. Copying does
  not depend on an application window staying open.
- **Line endings.** Copy expands each lone LF to CR LF; paste collapses CR LF to LF, so a
  `TextArea` never receives CR and other applications see its line breaks. Unpaired
  surrogates from other applications paste as U+FFFD.
- **Bounds.** 64 KiB of UTF-8 in each direction, as on Linux and fbdev; longer text is
  refused with a warning, never truncated. Paste scans at most 128 Ki units. A clipboard
  held by another process gets 5 attempts 5 ms apart, so it stalls the UI thread for at
  most 20 ms.
- **Allocation.** The system clipboard takes ownership of a `GlobalAlloc` block the copying
  process fills, so copy makes one allocation of at most 256 KiB, freed on every failure
  path. Paste returns caller-allocated text because the shared `getText` contract does.
  Both conflict with section 2 and belong to the phase 6 services redesign
  (`docs/platform_interface_design.md`), which no backend has done yet.
- **Shortcuts.** The text widgets read edit commands (select all, copy, cut, paste, undo,
  redo) through `text_common.hasEditCommandModifier`: Ctrl on Windows, `cmd` elsewhere.
  Windows reports the Win key as `cmd`, and the shell owns Win+V. Line and document
  navigation still use `cmd`, the macOS mapping.
- **Tests.** The `test-windows` clipboard tests use the real system clipboard and replace
  its contents.
- **Example.** `zig build run-clipboard` (`src/examples/clipboard.zig`, Windows build only)
  shows a `TextInput` and a `TextArea` with byte, LF, and CR counts. Verified by hand:
  copying between the two widgets works and the pasted text holds no CR. Not yet checked
  by hand: CR LF text from Notepad, copying back into Notepad, and emoji.

### File dialogs

`src/platform/windows/file_dialog.zig` implements `promptForPaths` and `promptForNewPath`
with the Common Item Dialog (`IFileOpenDialog`, `IFileSaveDialog`), and `gooey.file_dialog`
selects it with one `.windows` arm. The COM bindings are in `src/platform/windows/shell.zig`,
with every called slot pinned as in the WIC bindings.

- **Modality.** The dialog is owned by `GetActiveWindow()`. Its modal loop dispatches
  `WM_PAINT`, so Gooey windows keep drawing, but the platform loop does not turn. Open it
  from `cx.deferCommand`, which runs after input handling (`on_post_input`), not from
  inside a click handler; `src/examples/file_dialog.zig` now does this on every platform.
- **Options.** `message` is the title, `prompt` the OK button label, and
  `allowed_extensions` one filter (`*.zig;*.txt`) that is also the save dialog's default
  extension. `directories` picks folders only, as on Linux. `can_create_directories` is
  ignored: the dialog always offers a new folder. An unresolvable starting folder is
  logged and ignored, as on macOS. `FOS_NOCHANGEDIR` keeps the working directory, which
  examples use to find `assets/`.
- **Paths.** Results are WTF-8, the encoding Zig's file APIs take on Windows, so a name
  with an unpaired surrogate still opens.
- **COM.** Each call enters a single-threaded apartment and balances it; a thread already
  in the multithreaded apartment keeps it.
- **Bounds.** Labels and names 512 UTF-16 units, paths 32,767, at most 64 extensions in
  2,048 units, and at most 1,024 selected paths. Longer input fails the call with a
  warning; a larger selection is refused, never truncated. Scratch is about 72 KiB of
  stack per call. The returned paths are heap-allocated because the shared contract
  returns caller-owned paths; that conflicts with section 2 and belongs to the phase 6
  services redesign, like the clipboard.
- **Tests.** `test-windows` configures real dialogs with every option without showing
  them, reads the options back, and round-trips the working directory through an
  `IShellItem`. Showing a dialog needs a person: `zig build run-file-dialog`. Not yet
  checked by hand.

### Accessibility (UI Automation)

`src/accessibility/windows_bridge.zig` implements the shared `Bridge` with UI Automation
providers, and `createPlatformBridge` selects it with one `.windows` arm. The bindings are
hand-written in `src/platform/windows/uia.zig`; IIDs, slot orders, and constants were
checked against Zig's bundled `uiautomationcore.h`.

- **Pull model.** Clients query between frames, after the tree's borrowed strings may be
  gone, so each synced frame copies the tree into a snapshot the bridge owns
  (`windows_snapshot.zig`). Providers (`windows_provider.zig`) name elements by
  fingerprint, read only the snapshot, and report `UIA_E_ELEMENTNOTAVAILABLE` once their
  element is gone. The runtime id is the fingerprint.
- **Window.** `Window.uia_host` holds the root provider; `WM_GETOBJECT` with
  `UiaRootObjectId` returns it and makes the window render for one screen reader poll
  interval (60 frames), so an idle app activates promptly. The bridge is active once any
  client asked for the root or while `UiaClientsAreListening` is true.
- **Exposed.** Control types per role (`Role.toUiaControlType`), name, help text, focus,
  enabled, required, live setting, heading level, set position and size, ARIA role,
  bounds in physical screen pixels, hit testing, and focus. Patterns by role: Value, Range
  Value, Toggle, Expand Collapse, Selection Item. Events: focus, property changes,
  structure changes, and announcements as notification events (Windows 10 1709).
- **No actions.** The tree has no path back to the widgets, so `Invoke`, `Toggle`,
  `SetValue`, `SetFocus`, and similar return `UIA_E_NOTSUPPORTED`; screen readers fall
  back to keyboard and pointer input. This is a framework gap shared with macOS.
- **Threading.** The bridge enters an STA on the window's thread and providers report
  `UseComThreading`, so calls arrive through the message loop. An `SRWLOCK` guards the
  snapshot either way, and no event is raised while it is held, because a raise may call
  straight back into a provider. A render thread needs no further change.
- **Bounds.** 2,048 entries, at most 1 KiB of text per element (name 256 B, value 512 B,
  description 256 B, truncated at a code point boundary), 4,096 providers, and 128
  property events per frame; overflow invalidates the whole tree instead. About 2.7 MiB
  is reserved through `core/reservation.zig` and becomes resident only as it is used.
  `BSTR`, `SAFEARRAY`, and event marshaling allocate inside `oleaut32` and UI Automation,
  which the COM contract requires.
- **Pool exhaustion.** Returns `E_OUTOFMEMORY` to the client and warns once instead of
  failing fast, against section 2: the demand comes from another process, which must not
  be able to crash the app. Accepted for now, with the read-only scope and the 1709
  minimum.
- **Shared edit.** `Bridge.syncFrame` now calls `syncDirty` every synced frame, with an
  empty list when nothing changed, so moved bounds reach the snapshot. The other bridges
  already return early on an empty list.
- **Tests.** `test-windows` covers the snapshot (linking, copying, truncation, a full tree
  at every text cap, change detection, hit testing), the providers through their vtables
  against a hidden window (navigation, names, patterns, focus, screen-pixel hit testing,
  stale elements, pool exhaustion and reuse), and the bridge lifecycle with real UI
  Automation calls. Verified with an external client: the .NET `UIAutomationClient` from
  PowerShell walks `run-accessible-form`'s tree with correct control types, names, states,
  patterns, and runtime ids, and receives focus events as Tab moves through the fields.
  Not yet tried with Narrator or NVDA.

**Remaining gaps.** Each is its own commit or PR.

- **Actions.** Needs a framework path from an accessible element back to its widget's
  handler (press, toggle, set value, expand, select, focus). Shared with macOS, whose
  bridge exposes no actions either; the Windows pattern methods are where it plugs in.
- **Screen readers by hand.** Narrator and NVDA, including announcements and live
  regions, which the PowerShell client did not exercise. Structure-changed events on the
  root pass no runtime id; whether clients honour that is untested.
- **Text pattern.** Text fields expose only the Value pattern, so a screen reader reads
  the whole value but not the caret, selection, or words. Needs caret and selection in the
  accessibility tree first.
- **Relationships.** `labelled_by`, `described_by`, and `controls` are not exposed
  (`LabeledBy`, `DescribedBy`, `ControllerFor`); they need provider-valued properties.
- **Selection containers.** `SelectionContainer` returns null and lists, tab lists, and
  radio groups do not implement the Selection pattern.
- **Fingerprint collisions.** Every top-level element has position 0 in its fingerprint,
  so two top-level elements with the same role and name share a runtime id and the
  snapshot resolves both to the first. A tree-wide issue; the flat example tree below
  makes it more likely.
- **Old values.** Property-changed events carry the new value and `VT_EMPTY` as the old.
- **Render thread.** The snapshot lock already covers a frame built off the window's
  thread; `uia.Host.client_requested` would then need to become atomic.

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

## Framework gaps seen from Windows

These are not Windows defects and need no backend work; they are recorded here because
they surface while testing the port.

- **Mouse text selection.** Not implemented on any platform. A click in a `TextInput` or
  `TextArea` only focuses it (`handleTextAreaClick` in `src/runtime/input.zig`), drags
  reach only scrollbars and drag-and-drop (`handleMouseMoveEvent` discards `is_drag`), and
  no text API maps a point to a byte offset. The Windows translator already reports
  `mouse_down` with a click count and `mouse_dragged` while a button is held, so the
  feature needs only shared work: point to byte offset from shaped advances, caret
  placement and Shift+click, drag-extend from an anchor, and double- and triple-click
  word and line selection. `src/runtime/input.zig` is rewritten in phases 3–6, so decide
  whether it lands before or as part of that rewrite.
- **Linux edit shortcuts.** `linux/input.zig` maps Super to `cmd`, and the text widgets'
  edit commands use `cmd` outside Windows, so Linux text fields appear to copy with
  Super+C rather than Ctrl+C. Inferred from the code, not tried on Linux.
- **Accessible form example.** `src/examples/accessible_form.zig` closes each accessible
  element straight after opening it (`defer cx.accessibleEnd()` inside the `if`) and gives
  most no `layout_id`. The tree comes out flat, and headings, groups, and radio buttons
  have no bounds, so a screen reader cannot point at them. Inferred from the code and the
  UI Automation tree; the macOS tree should show the same.
- **Build output.** `zig build test-windows` prints `failed command: ...test.exe` whenever
  a test logs a warning, even though the summary reports every test passing.

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
- [ ] CI: run `typecheck-windows` next to `typecheck-linux`, which runs in the macOS job
      of `.github/workflows/ci.yml`.
- [ ] Wire `root.zig`'s test block up for Windows; `test-windows` covers only the
      backends.
- [x] SVG rasterization (software rasterizer, fixed scratch arena).
- [ ] Text: font fallback (`IDWriteFontFallback::MapCharacters` can reuse the analysis
      source), bidi, color glyphs.
- [ ] IME (`WM_IME_*`, caret rect from the read-only query).
- [x] Clipboard (`CF_UNICODETEXT`, Ctrl edit shortcuts in the text widgets,
      `run-clipboard`).
- [x] File dialogs (Common Item Dialog, `run-file-dialog`).
- [x] Accessibility through UI Automation (read-only; see the section above).
- [ ] Frame pacing on a render thread.
