# iPad/iPadOS Support — Implementation Plan

## Executive Summary

Gooey's architecture is well-positioned for iPad support. The platform abstraction layer (`platform/interface.zig`), compile-time backend selection (`platform/mod.zig`), and shared rendering primitives (`platform/unified.zig`) were designed for exactly this kind of expansion. Metal, CoreText, and CoreGraphics — the three Apple frameworks Gooey depends on — are all available on iPadOS with identical APIs. The core work is replacing AppKit windowing and input with UIKit equivalents.

**Estimated effort**: 4–6 weeks across 5 phases.
**Reusable without changes**: ~70% of the codebase (layout, scene graph, components, widgets, animation, text, Metal shaders).

---

## Current Platform Matrix

| Platform | Windowing                                      | GPU       | Text                 | SVG              | Image                    | VSync                                  | Dispatcher               |
| -------- | ---------------------------------------------- | --------- | -------------------- | ---------------- | ------------------------ | -------------------------------------- | ------------------------ |
| macOS    | AppKit (`NSApplication`, `NSWindow`, `NSView`) | Metal     | CoreText             | CoreGraphics     | CoreGraphics/ImageIO     | `CVDisplayLink` (dedicated thread)     | GCD (`dispatch_async_f`) |
| Linux    | Wayland                                        | Vulkan    | FreeType/HarfBuzz    | Cairo (software) | libpng                   | Wayland frame callbacks                | eventfd                  |
| Web      | Canvas/DOM                                     | WebGPU    | Canvas2D measureText | Canvas2D Path2D  | Canvas2D drawImage       | `requestAnimationFrame`                | N/A (single-threaded)    |
| **iPad** | **UIKit**                                      | **Metal** | **CoreText**         | **CoreGraphics** | **CoreGraphics/ImageIO** | **`CADisplayLink` (dedicated thread)** | **GCD**                  |

Key insight: iPad shares Metal, CoreText, CoreGraphics, and GCD with macOS. Only the windowing/input/vsync layer differs.

---

## What's Reusable As-Is (Zero Changes)

These directories and files require no modification:

```
src/
├── core/            # geometry, events, shaders, interface_verify — all platform-agnostic
├── layout/          # Flexbox engine — pure computation, no platform deps
├── scene/           # Scene graph, batching, draw ordering — pure data
├── context/         # Gooey, Cx, focus, entity, dispatch, widget store
├── animation/       # Easing, spring physics, motion — pure math
├── components/      # Button, TextInput, Modal, Tooltip, etc. — declarative
├── widgets/         # Stateful widget impls (text input/area state)
├── ui/              # Builder, vstack, hstack, box — declarative
├── debug/           # Render stats, diagnostics
├── validation.zig   # Form validation — pure logic
├── cx.zig           # Unified context
├── app.zig          # App entry points (CxConfig, runCx dispatch)
│
├── platform/
│   ├── interface.zig       # PlatformVTable, WindowVTable, PlatformCapabilities, WindowOptions
│   ├── unified.zig         # Unified GPU primitive (128-byte Primitive struct) — all platforms
│   ├── window_registry.zig # WindowId, WindowRegistry — platform-agnostic
│   └── time.zig            # Platform time utilities
│
├── runtime/
│   ├── render.zig          # Scene → GPU command translation (uses interfaces, not platform types)
│   ├── frame.zig           # Frame rendering orchestration
│   ├── input.zig           # Input → Cx event translation
│   ├── window_context.zig  # Per-window context (generic over platform Window)
│   └── multi_window_app.zig
│
├── text/
│   ├── atlas.zig           # Texture atlas — pure data structure
│   ├── cache.zig           # Glyph cache — uses FontFace interface
│   ├── types.zig           # Metrics, ShapedGlyph, ShapedRun — pure types
│   ├── font_face.zig       # FontFace trait — interface definition
│   ├── shaper.zig          # Shaper interface + simple shaper
│   ├── render.zig          # renderText utility
│   └── text_system.zig     # High-level API (selects backend at comptime)
│
├── image/
│   └── atlas.zig           # ImageAtlas, ImageKey, caching — pure data
│
└── svg/
    └── atlas.zig           # SvgAtlas, caching, per-frame budget — pure data
```

## What's Reusable with a One-Line Change

These files use compile-time `switch` on `builtin.os.tag` for backend selection. Each needs `.ios` added alongside `.macos`:

| File                     | Current Switch                                     | Change                                                       |
| ------------------------ | -------------------------------------------------- | ------------------------------------------------------------ |
| `src/platform/mod.zig`   | `.macos => macos/mod.zig, .linux => linux/mod.zig` | Add `.ios => ios/mod.zig`                                    |
| `src/svg/rasterizer.zig` | `.macos => coregraphics.zig, .linux => cairo.zig`  | Change to `.macos, .ios => coregraphics.zig` (same backend!) |
| `src/image/loader.zig`   | `.macos => coregraphics.zig, .linux => libpng.zig` | Change to `.macos, .ios => coregraphics.zig` (same backend!) |

**Note on `src/text/text_system.zig`**: This file uses `if/else if/else` chains, not `switch`. The `else` branch already catches everything that isn't WASM or Linux — iOS falls through to CoreText automatically. **Zero changes needed.**

The CoreText, CoreGraphics, and ImageIO backends are shared verbatim — no new code needed for text, SVG, or image loading.

## What Needs the `is_apple` Treatment

Several files gate functionality behind `builtin.os.tag == .macos` where the actual intent is "Apple platform with CoreText/CoreGraphics/Metal/GCD". Rather than patching each one individually, we introduce a shared `is_apple` constant (see Phase 1.2) and sweep these files:

| File                                  | Current Gate                            | What It Controls                                                                                                       |
| ------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `src/runtime/window_context.zig`      | `is_mac = ... builtin.os.tag == .macos` | Metal atlas upload callbacks (`setupWindow`, `uploadTextAtlasLocked`, etc.) — **critical for rendering**               |
| `src/text/types.zig`                  | `is_macos = builtin.os.tag == .macos`   | `CFRelease` for CoreText fallback fonts in `ShapedRun.deinit` — iOS needs this too                                     |
| `src/svg/mod.zig`                     | `builtin.os.tag == .macos`              | CoreGraphics backend export in `backends` struct                                                                       |
| `src/context/gooey.zig`               | `builtin.os.tag == .macos` (×4 sites)   | `window.ns_window`/`window.ns_view` for accessibility bridge init — needs `nativeHandle()` abstraction (see Phase 2.2) |
| `src/accessibility/accessibility.zig` | `builtin.os.tag == .macos` (4 sites)    | `mac_bridge` import, `MacBridge` type, `PlatformBridge` union, `createPlatformBridge`                                  |
| `src/accessibility/mod.zig`           | `builtin.os.tag == .macos`              | Same `mac_bridge` gate                                                                                                 |

**Important**: The accessibility gates should **not** be blindly changed to `is_apple` — iPadOS uses `UIAccessibility`, not `NSAccessibility`. See Open Questions for the plan. The other files (`window_context.zig`, `text/types.zig`, `svg/mod.zig`) should use `is_apple`.

The `gooey.zig` case is special — it accesses `window.ns_window` and `window.ns_view` by field name, but the iOS Window struct uses `ui_window`/`ui_view`. This requires a `Window.nativeWindowHandle()`/`nativeViewHandle()` accessor (see Phase 2.2).

## What Needs New Code

A new `src/platform/ios/` directory with ~9 files, a shared `src/platform/apple/` module for common Apple types, input event extensions, and build system changes.

---

## Phase 1: Build System & Target Detection

**Goal**: Get Zig cross-compiling for `aarch64-ios`, produce a linkable static library, establish the compile-time detection plumbing.

**Duration**: 3–5 days

### 1.1 — Add iOS target detection to `build.zig`

**Primary approach**: Zig builds a static library. A thin Xcode project links it and handles code signing, provisioning, and deployment. This sidesteps Zig's iOS cross-compilation immaturity and App Store packaging complexity (see Risk Register). The `build.zig` changes below support both the static lib target and direct compilation.

```zig
// build.zig — new detection alongside existing is_native_macos / is_native_linux
const is_native_ios = target.result.os.tag == .ios;
```

Add a new `if (is_native_ios)` block that:

- Creates the gooey module with `root_source_file = b.path("src/root.zig")`
- Imports `zig_objc` (same dependency — the Objective-C runtime is identical on iOS)
- Links UIKit, Metal, QuartzCore, CoreFoundation, CoreVideo, CoreText, CoreGraphics frameworks
- Does **not** link AppKit
- Builds gooey as a **static library** (not executable) — the Xcode wrapper project links this (see Phase 5.4)
- Adds a minimal `ios-demo` example target

```zig
if (is_native_ios) {
    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("gooey", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("objc", objc_dep.module("objc"));

    // UIKit instead of AppKit
    mod.linkFramework("UIKit", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("CoreText", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.link_libc = true;
}
```

### 1.2 — Add `.ios` to platform backend selection and introduce `is_apple`

In `src/platform/mod.zig`, introduce `is_apple` — a single constant that means "Apple platform with CoreText/CoreGraphics/Metal/GCD". This prevents a whack-a-mole situation as we discover scattered `.macos` checks:

```zig
pub const is_ios = builtin.os.tag == .ios;

/// True for any Apple platform (macOS, iOS). Use this instead of checking
/// `.macos` directly when the intent is "platform with CoreText/CoreGraphics/Metal/GCD".
/// This prevents missing scattered `.macos` gates when adding new Apple targets.
pub const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
    .ios => @import("ios/mod.zig"),       // NEW
    .linux => @import("linux/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const Platform = if (is_wasm)
    backend.WebPlatform
else if (is_linux)
    backend.LinuxPlatform
else if (is_ios)
    backend.iOSPlatform                   // NEW
else
    backend.MacPlatform;

pub const Window = if (is_wasm)
    backend.WebWindow
else if (is_linux)
    backend.Window
else
    backend.Window;                       // iOS and macOS both export `backend.Window`

pub const DisplayLink = if (is_wasm)
    void
else if (is_linux)
    void
else if (is_ios)
    backend.DisplayLink                   // CADisplayLink wrapper
else
    backend.DisplayLink;                  // CVDisplayLink (macOS, unchanged)

pub const Dispatcher = if (is_wasm)
    void
else if (is_linux)
    backend.dispatcher.Dispatcher
else
    backend.dispatcher.Dispatcher;        // GCD — shared between macOS and iOS
```

Then update all files that check `builtin.os.tag == .macos` where the intent is "Apple platform":

```zig
// src/runtime/window_context.zig — CRITICAL: enables Metal atlas uploads on iOS
const is_apple = platform.is_apple;  // was: const is_mac = ... builtin.os.tag == .macos

// src/text/types.zig — enables CFRelease for CoreText fallback fonts on iOS
const is_apple = platform.is_apple;  // was: const is_macos = builtin.os.tag == .macos

// src/svg/mod.zig — enables CoreGraphics backend export on iOS
// Change: builtin.os.tag == .macos  →  platform.is_apple
```

**Do NOT change** the accessibility gates (`accessibility.zig`, `mod.zig`) to `is_apple` yet — iPadOS accessibility uses `UIAccessibility`, not `NSAccessibility`. Those need a separate iOS bridge (deferred to a later phase).

Full sweep list:

- `src/text/types.zig`: `const is_macos = ...` → `const is_apple = platform.is_apple;` (update all references)
- `src/runtime/window_context.zig`: `const is_mac = ...` → `const is_apple = platform.is_apple;` (update all references)
- `src/svg/mod.zig`: `builtin.os.tag == .macos` → `platform.is_apple`
- `src/context/gooey.zig`: needs `nativeHandle()` accessors — see Phase 2.2

### 1.3 — Route SVG/image backends for `.ios`

In `src/svg/rasterizer.zig`:

```zig
const backend = if (is_wasm)
    @import("backends/canvas.zig")
else switch (builtin.os.tag) {
    .macos, .ios => @import("backends/coregraphics.zig"),  // same backend
    .linux => @import("backends/cairo.zig"),
    else => @import("backends/null.zig"),
};
```

Same pattern for `src/image/loader.zig` — add `.ios` alongside `.macos` in the switch arm.

**Text system**: No changes needed. `src/text/text_system.zig` uses `if/else if/else` chains — the `else` branch already selects CoreText for any non-WASM, non-Linux target, so iOS gets CoreText automatically.

### 1.3a — Extract shared Apple types to `src/platform/apple/`

Currently `src/platform/macos/appkit.zig` defines `NSPoint`/`NSSize`/`NSRect` which are typedefs for `CGPoint`/`CGSize`/`CGRect`. Rather than importing a file called "appkit.zig" on iOS (confusing and fragile), extract the shared geometry types:

```
New file: src/platform/apple/core_graphics_types.zig

  pub const CGPoint = extern struct { x: f64, y: f64 };
  pub const CGSize  = extern struct { width: f64, height: f64 };
  pub const CGRect  = extern struct { origin: CGPoint, size: CGSize };

  // Aliases for AppKit compatibility
  pub const NSPoint = CGPoint;
  pub const NSSize  = CGSize;
  pub const NSRect  = CGRect;
```

Update `src/platform/macos/appkit.zig` to re-export from the shared module. The iOS backend imports from `apple/` directly.

### 1.4 — Create stub `src/platform/ios/mod.zig`

Minimal module that compiles but panics at runtime — proves the build pipeline works end-to-end.

```zig
// src/platform/ios/mod.zig
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const display_link = @import("display_link.zig");
pub const dispatcher = @import("../macos/dispatcher.zig"); // GCD — shared with macOS
pub const unified = @import("../unified.zig");

pub const iOSPlatform = platform.iOSPlatform;
pub const Window = window.Window;
pub const DisplayLink = display_link.DisplayLink;
```

### 1.5 — Verify cross-compilation

```sh
zig build -Dtarget=aarch64-ios
```

This should compile cleanly even if the binary can't run yet. The goal is catching link errors (missing framework symbols, ObjC runtime differences) early.

### Deliverable

- `zig build -Dtarget=aarch64-ios` compiles without errors
- All existing macOS/Linux/WASM builds unaffected
- Platform selection compiles the iOS backend on iOS targets
- `is_apple` constant available and used in `window_context.zig`, `text/types.zig`, `svg/mod.zig`

---

## Phase 2: UIKit Platform Shell (Window + Rendering)

**Goal**: Get a colored rectangle on screen on iPad. Metal renders, UIKit hosts.

**Duration**: 1–2 weeks

### 2.1 — `src/platform/ios/platform.zig` — UIKit Application Lifecycle

Replaces `src/platform/macos/platform.zig` (which uses `NSApplication`).

UIKit uses `UIApplicationMain()` which never returns — it owns the run loop. The iOS platform struct must integrate with this model.

```
New file: src/platform/ios/platform.zig

Key type: iOSPlatform
  - window_registry: WindowRegistry
  - allocator: std.mem.Allocator
  - running: bool
  - app_init_fn: ?*const fn(*iOSPlatform) void  // User's app setup callback

  capabilities = PlatformCapabilities{
      .high_dpi = true,               // All iPads are Retina
      .multi_window = false,          // Single-scene initially (multi-scene deferred — see Resolved Questions)
      .gpu_accelerated = true,
      .display_link = true,
      .can_close_window = false,      // No window chrome on iPad
      .glass_effects = false,         // No NSVisualEffectView equivalent (use UIBlurEffect)
      .clipboard = true,              // UIPasteboard
      .file_dialogs = true,           // UIDocumentPickerViewController
      .ime = true,                    // UITextInput protocol
      .custom_cursors = false,        // No cursor on iPad (until trackpad connected)
      .window_drag_by_content = false,
      .name = "iPadOS",
      .graphics_backend = "Metal",
  }

  init() — Creates UIApplication shared instance
  run()  — Calls UIApplicationMain (or runs CFRunLoop if already inside UIKit lifecycle)
  quit() — No-op or UIApplication.terminate (not standard on iOS)
```

**Critical difference from macOS — inversion of control**: On macOS, `MacPlatform.run()` is a manual event loop (`nextEventMatchingMask:untilDate:inMode:dequeue:` in a `while` loop). The user calls `run()` and it blocks, but the user's setup code runs _before_ `run()`.

On iOS, `UIApplicationMain()` also blocks — but it takes over _everything_. The initialization sequence becomes:

**macOS flow** (user controls):

1. `main()` → `MacPlatform.init()` → create windows, set up `Gooey`, components, etc.
2. `platform.run()` → enters `NSApplication` event loop, blocks until quit

**iOS flow** (UIKit controls):

1. `main()` stores the user's app setup function in `iOSPlatform`, then calls `UIApplicationMain(argc, argv, nil, "GooeyAppDelegate")`
2. `UIApplicationMain` **never returns** — UIKit takes over immediately
3. UIKit creates the `UIApplication`, instantiates `GooeyAppDelegate`
4. UIKit calls `application:didFinishLaunchingWithOptions:` on the delegate
5. Inside that delegate callback: create `UIWindow`, `UIViewController`, `GooeyMetalView`, start `CADisplayLink`
6. The delegate calls back into the user's stored app setup function — this is where `Gooey` init, component setup, etc. happen

This means the user's effective entry point moves into a callback. The `iOSPlatform` struct stores this callback so the inversion is transparent:

```zig
// User code (similar to macOS pattern but setup is deferred):
pub fn main() !void {
    var platform = try iOSPlatform.init(allocator);
    platform.setAppInit(myAppSetup);  // Store callback
    platform.run();                    // Calls UIApplicationMain — never returns
}

fn myAppSetup(platform: *iOSPlatform) void {
    // Called from application:didFinishLaunchingWithOptions:
    var window = try platform.createWindow(.{});
    var gooey = try Gooey.initOwned(allocator, window, .{});
    // ... set up components, scenes, etc.
}
```

### 2.2 — `src/platform/ios/window.zig` — UIWindow + Metal Layer + `nativeHandle()`

Replaces `src/platform/macos/window.zig` (which uses `NSWindow` + `NSView` + `CAMetalLayer`).

```
New file: src/platform/ios/window.zig

Key type: Window (same name as macOS, selected at comptime)
  Fields — mirrors macOS Window from src/platform/macos/window.zig:
    allocator: std.mem.Allocator
    ui_window: objc.Object          // UIWindow (was ns_window)
    ui_view: objc.Object            // UIView subclass (was ns_view)
    metal_layer: objc.Object        // CAMetalLayer (same!)
    renderer: metal.Renderer        // SHARED — exact same Metal renderer
    display_link: DisplayLink       // CADisplayLink wrapper (Phase 2.3)
    size: geometry.Size(f64)
    scale_factor: f64
    needs_render: std.atomic.Value(bool)
    scene: ?*const scene_mod.Scene
    text_atlas: ?*const Atlas
    svg_atlas: ?*const Atlas
    image_atlas: ?*const Atlas
    render_mutex: std.Thread.Mutex
    // ... same atlas upload callbacks as macOS

  Methods — same signatures as macOS window.zig:
    init(allocator, *iOSPlatform, Options) !*Self
    deinit(*Self) void
    width/height/getSize/getScaleFactor
    setScene/setTextAtlas/setSvgAtlas/setImageAtlas
    requestRender/render
    handleInput/handleResize
    interface() WindowVTable
    getRendererCapabilities() RendererCapabilities
    nativeWindowHandle() objc.Object    // NEW — returns ui_window
    nativeViewHandle() objc.Object      // NEW — returns ui_view
```

**`nativeHandle()` accessors — cross-platform window identity**

`src/context/gooey.zig` currently accesses `window.ns_window` and `window.ns_view` by field name (4 sites) to initialize the accessibility bridge. The iOS Window has `ui_window`/`ui_view` instead. Rather than adding compile-time switches in `gooey.zig` for every field name, both macOS and iOS Window types expose uniform accessors:

```zig
// On macOS Window (add to src/platform/macos/window.zig):
pub fn nativeWindowHandle(self: *const Self) objc.Object { return self.ns_window; }
pub fn nativeViewHandle(self: *const Self) objc.Object { return self.ns_view; }

// On iOS Window (src/platform/ios/window.zig):
pub fn nativeWindowHandle(self: *const Self) objc.Object { return self.ui_window; }
pub fn nativeViewHandle(self: *const Self) objc.Object { return self.ui_view; }
```

Then `gooey.zig` becomes:

```zig
const window_obj = if (platform.is_apple) window.nativeWindowHandle() else null;
const view_obj = if (platform.is_apple) window.nativeViewHandle() else null;
result.a11y_bridge = a11y.createPlatformBridge(&result.a11y_platform_bridge, window_obj, view_obj);
```

This replaces the current `builtin.os.tag == .macos` checks with a single `is_apple` gate and field-name-agnostic accessors. The platform difference is contained within the window modules.

**What changes vs macOS window.zig**:

| macOS (`src/platform/macos/window.zig`)                         | iPad (`src/platform/ios/window.zig`)                            | Notes                                                           |
| --------------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| `NSWindow.alloc().initWithContentRect:styleMask:backing:defer:` | `UIWindow.alloc().initWithWindowScene:`                         | Different init, simpler (no style mask, no backing store)       |
| `NSWindow.setContentView:` with custom `GooeyMetalView`         | `UIWindow.rootViewController.view` with custom `GooeyMetalView` | Must use `UIViewController` as intermediary                     |
| `CAMetalLayer` setup via `NSView.setWantsLayer:` + `layer`      | `CAMetalLayer` setup via `UIView.layer` class override          | `UIView` can declare `CAMetalLayer` as its layer class directly |
| `NSScreen.mainScreen.backingScaleFactor`                        | `UIScreen.mainScreen.scale`                                     | Same concept, different API                                     |
| Title bar, style mask, resize handles                           | None — always full-screen or split-view                         | Simpler                                                         |
| `NSTrackingArea` for mouse enter/exit                           | Not needed (touch-based)                                        | Removed                                                         |
| `setupGlassEffect` / liquid glass                               | Not applicable                                                  | Skip (UIBlurEffect is a future enhancement)                     |

**What's identical**:

- `CAMetalLayer` configuration (`pixelFormat`, `device`, `framebufferOnly`)
- The entire `metal.Renderer` — import directly from `../macos/metal/metal.zig`
- Atlas upload callbacks (`text_atlas_upload_fn`, etc.)
- `render_mutex` pattern
- `needs_render` atomic flag
- Scene/atlas setters

### 2.3 — `src/platform/ios/display_link.zig` — CADisplayLink on Dedicated Thread

Replaces `src/platform/macos/display_link.zig` (which uses `CVDisplayLink`).

**Design principle**: macOS uses `CVDisplayLink` on a dedicated CoreVideo thread for maximum rendering performance. iPad uses `CADisplayLink` — but we run it on a **dedicated render thread**, not the main thread, preserving the same threading model. The render callback, mutex locking, and atlas upload pattern remain identical.

```
New file: src/platform/ios/display_link.zig

Key type: DisplayLink
  Fields:
    link: objc.Object              // CADisplayLink instance
    render_thread: ?std.Thread     // Dedicated render thread
    running: std.atomic.Value(bool)

  init() !Self
    - Creates CADisplayLink via CADisplayLink.displayLinkWithTarget:selector:
    - Does NOT add to any run loop yet (added on start)

  start(*Self) !void
    - Spawns a dedicated std.Thread
    - Thread function:
      1. Creates NSRunLoop for the thread
      2. Adds CADisplayLink to the thread's run loop
      3. Configures ProMotion: link.preferredFrameRateRange = {80, 120, 120}
      4. Runs the run loop (blocks until stop)
    - Stores running = true

  stop(*Self) void
    - Calls link.invalidate() (removes from run loop, causes thread to exit)
    - Joins render thread
    - Stores running = false

  deinit(*Self) void
    - Calls stop()
    - No CVDisplayLinkRelease equivalent needed (CADisplayLink is auto-released on invalidate)

  getRefreshRate(*Self) f64
    - iPad Pro: 120Hz (ProMotion)
    - iPad Air/Mini: 60Hz
    - Reads from CADisplayLink.preferredFrameRateRange or falls back to 60.0
```

The render callback (equivalent to `displayLinkCallback` in `src/platform/macos/window.zig` L1164-1275) lives in `window.zig` and follows the exact same pattern:

1. Check `in_live_resize` (for iPad: check multitasking resize)
2. Check `needs_render` atomic
3. Acquire `render_mutex`
4. Call `on_render` callback
5. Upload atlases (text, SVG, image) via thread-safe callbacks
6. Call `renderer.renderScene()` or `renderer.renderSceneWithPostProcess()`

### 2.4 — Share the Metal renderer

The entire `src/platform/macos/metal/` directory is imported by the iOS window, not copied:

```zig
// src/platform/ios/window.zig
const metal = @import("../macos/metal/metal.zig");
```

Metal API is binary-compatible between macOS and iOS. Same shader language (MSL), same pipeline state objects, same command buffers, same texture formats. The `renderer.zig`, `pipelines.zig`, `scene_renderer.zig`, `text.zig`, `svg_pipeline.zig`, `image_pipeline.zig`, `custom_shader.zig` — all shared.

**Note on `window_context.zig`**: The `is_apple` gate change from Phase 1.2 is what makes this sharing work end-to-end. Without it, `setupWindow()` skips the atlas upload callback wiring on iOS, and the Metal renderer never receives glyph/SVG/image atlas updates — resulting in invisible text and images despite the renderer itself working fine.

> **Future cleanup**: Consider moving `metal/` to `src/platform/apple/metal/` alongside `core_graphics_types.zig` so neither platform "owns" the shared code. Not required for initial iPad support — the import path works fine from `ios/` → `../macos/metal/`.

### 2.5 — Register UIView subclass for Metal rendering

Similar to `src/platform/macos/input_view.zig` which registers `GooeyMetalView` as an NSView subclass, we need a UIView subclass:

```
New file: src/platform/ios/metal_view.zig

Registers "GooeyMetalView" as a UIView subclass using zig-objc:
  - layerClass class method → returns CAMetalLayer class
  - Stores pointer to Zig Window in an ivar (same pattern as macOS input_view.zig)
  - Touch event methods (Phase 3)
```

### Deliverable

- A solid-color Metal-rendered rectangle visible on iPad Simulator
- `CADisplayLink` firing on a dedicated thread at the correct refresh rate
- `render_mutex`-protected rendering path matching macOS architecture
- **macOS `CVDisplayLink` completely unchanged** — lives in its own backend directory

---

## Phase 3: Input — Touch Events + Pointer Compatibility

**Goal**: All existing components (Button, TextInput, etc.) respond to touch on iPad.

**Duration**: 1–2 weeks

### 3.1 — Extend `InputEvent` with touch variants

In `src/input/events.zig`, add touch event types alongside existing mouse events:

```zig
// New types in src/input/events.zig

pub const TouchPhase = enum(u8) {
    began,
    moved,
    stationary,
    ended,
    cancelled,
};

pub const TouchEvent = struct {
    /// Unique identifier for this touch (for multi-touch tracking)
    touch_id: u64,
    /// Position in logical pixels (same coordinate space as MouseEvent.position)
    position: geometry.Point(f64),
    /// Touch phase
    phase: TouchPhase,
    /// Force (0.0–1.0 on capable devices, 0.0 if unavailable)
    force: f32,
    /// Maximum possible force for this device
    max_force: f32,
    /// Number of taps (1 = single tap, 2 = double tap)
    tap_count: u32,
    /// Timestamp (for velocity calculation)
    timestamp_ms: i64,
};

pub const InputEvent = union(enum) {
    // Existing mouse events — unchanged
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_moved: MouseEvent,
    mouse_dragged: MouseEvent,
    mouse_entered: MouseEvent,
    mouse_exited: MouseEvent,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    modifiers_changed: Modifiers,
    text_input: TextInputEvent,
    composition: CompositionEvent,

    // NEW — touch events
    touch_down: TouchEvent,     // Finger contacted screen
    touch_moved: TouchEvent,    // Finger moved on screen
    touch_up: TouchEvent,       // Finger lifted
    touch_cancelled: TouchEvent, // System cancelled touch (e.g., incoming call)
};
```

### 3.2 — Touch-to-mouse translation layer

**This is the key enabler for rapid bring-up.** Rather than modifying every component to understand touch, we translate single-finger touches to mouse events at the platform boundary:

```
New file: src/platform/ios/touch_adapter.zig

Purpose: Converts primary touch to mouse events so all existing components work immediately.

Logic:
  touchesBegan   → InputEvent.mouse_down  (position from touch, button = .left, click_count = tap_count)
  touchesMoved   → InputEvent.mouse_dragged (if touch is active)
                  + InputEvent.mouse_moved (for hover simulation)
  touchesEnded   → InputEvent.mouse_up
  touchesCancelled → InputEvent.mouse_up (synthetic, prevents stuck states)

Additional hover simulation:
  - On touch_down: emit mouse_entered before mouse_down
  - On touch_up: emit mouse_exited after mouse_up
  - This makes Button hover states flash briefly on tap (natural feel)
```

This means `Button.on_click_handler`, `TextInput` focus, `Select` dropdown, `Modal` dismiss, scrolling in `VirtualList`/`UniformList`, `DataTable` row clicks — all work with zero changes to component code.

### 3.3 — Register touch handlers in `metal_view.zig`

In the UIView subclass registered in Phase 2.5, add ObjC method implementations:

```zig
// src/platform/ios/metal_view.zig — touch event methods

// Register with zig-objc:
cls.addMethod("touchesBegan:withEvent:", touchesBegan);
cls.addMethod("touchesMoved:withEvent:", touchesMoved);
cls.addMethod("touchesEnded:withEvent:", touchesEnded);
cls.addMethod("touchesCancelled:withEvent:", touchesCancelled);

fn touchesBegan(self: objc.Object, sel: objc.SEL, touches: objc.Object, event: objc.Object) void {
    const window = getWindow(self);   // Retrieve *Window from ivar
    const touch_set = touches;        // NSSet<UITouch *>
    const enumerator = touch_set.msgSend(objc.Object, "objectEnumerator", .{});

    while (enumerator.msgSend(?objc.Object, "nextObject", .{})) |touch| {
        const location = touch.msgSend(CGPoint, "locationInView:", .{self});
        const tap_count = touch.msgSend(c_long, "tapCount", .{});
        const force = touch.msgSend(f64, "force", .{});
        const max_force = touch.msgSend(f64, "maximumPossibleForce", .{});

        // Convert to Gooey TouchEvent, then pass through touch_adapter
        // for mouse compatibility
        window.handleTouch(.{
            .touch_id = @intFromPtr(touch.value),
            .position = .{ .x = location.x, .y = location.y },
            .phase = .began,
            .force = @floatCast(force),
            .max_force = @floatCast(max_force),
            .tap_count = @intCast(tap_count),
            .timestamp_ms = std.time.milliTimestamp(),
        });
    }
}
```

### 3.4 — Scroll via two-finger pan

For `VirtualList`, `UniformList`, `DataTable`, and any scrollable container:

```
Two-finger touch tracking in touch_adapter.zig:
  - Track touches by ID
  - When 2+ simultaneous touches move, emit InputEvent.scroll
  - delta = average movement of all active touches
  - This maps directly to existing ScrollEvent handling in components
```

### 3.5 — iPad trackpad/mouse support (low effort bonus)

iPadOS supports USB/Bluetooth mice and the Magic Trackpad. When a pointer device is connected, UIKit delivers `UIHoverGestureRecognizer` events and pointer-style touch events. These map 1:1 to existing mouse events — the touch adapter can detect `touch.type == .indirectPointer` and skip the translation, forwarding as native mouse events.

### Deliverable

- Tap a `Button` → `on_click_handler` fires
- Tap a `TextInput` → gains focus, cursor appears
- Scroll a `VirtualList` → smooth scrolling
- All existing examples run with touch input
- Raw `TouchEvent` available for apps that want multi-touch
- Trackpad/mouse input works when hardware is connected

---

## Phase 4: Text Input, Clipboard, File Dialogs

**Goal**: Full text editing, copy/paste, and file operations on iPad.

**Duration**: 1 week

### 4.1 — Software keyboard integration

On macOS, `GooeyMetalView` implements `NSTextInputClient` for IME. On iPad, the equivalent is `UITextInput` protocol, plus managing the software keyboard lifecycle.

```
New file: src/platform/ios/text_input.zig

UITextInput protocol conformance for GooeyMetalView:
  - hasText → checks if TextInput widget has content
  - insertText: → emits InputEvent.text_input  (same as macOS NSTextInputClient)
  - deleteBackward → emits InputEvent.key_down with key = .delete
  - setMarkedText:selectedRange: → emits InputEvent.composition (same as macOS IME)
  - unmarkText → commits composition

  The existing TextInputEvent and CompositionEvent types in events.zig
  handle this identically to macOS IME — the protocol surface differs
  but the semantic events are the same.

Keyboard show/hide:
  - Observe UIKeyboardWillShowNotification / UIKeyboardWillHideNotification
  - On show: report keyboard height to the Window
  - Window adjusts viewport (or scrolls focused TextInput into view)
  - On hide: restore viewport

  Implementation: Add keyboard_inset_bottom: f32 to Window struct.
  The layout engine reads this via Cx to adjust available height.
```

### 4.2 — Clipboard

```
New file: src/platform/ios/clipboard.zig

Mirrors src/platform/macos/clipboard.zig but uses UIPasteboard:

  getText(allocator) ?[]const u8
    - UIPasteboard.generalPasteboard.string → extract UTF-8

  setText(text: []const u8) void
    - UIPasteboard.generalPasteboard.setString:

API is actually simpler than macOS NSPasteboard (no pasteboard types to manage).
```

### 4.3 — File dialogs

```
New file: src/platform/ios/file_dialog.zig

Replaces NSOpenPanel/NSSavePanel with UIDocumentPickerViewController:

  promptForPaths(allocator, PathPromptOptions) ?PathPromptResult
    - Creates UIDocumentPickerViewController with appropriate UTTypes
    - Presents modally on the root UIViewController
    - Returns selected file URLs as paths via completion callback

  promptForNewPath(allocator, SavePromptOptions) ?[]const u8
    - UIDocumentPickerViewController in export mode
```

**⚠️ Deadlock risk**: `UIDocumentPickerViewController` must be presented on the main thread, and its delegate callback fires on the main thread. If `promptForPaths` is called from a button click handler that runs on the main thread and blocks on a semaphore there, it will deadlock. Two options:

1. **Dispatch presentation to main, wait on render thread**: Present the picker on main via GCD, wait on the semaphore from the render/CADisplayLink thread (where button handlers actually run — this should be safe). Return the result via `Dispatcher.dispatch` back to the caller.
2. **Make the API callback-based on iOS**: `promptForPaths` takes a completion callback instead of returning synchronously. This is the cleaner design but requires a small API divergence from macOS.

Recommend option 1 for initial implementation since Gooey's render callbacks run on the dedicated CADisplayLink thread (not the main thread). But this **must be verified early** — if any code path calls `promptForPaths` from the main thread directly, it will deadlock.

### Deliverable

- Type in a `TextInput` using the iPad software keyboard
- Emoji picker works (via UITextInput IME path)
- Copy/paste text between Gooey app and other iPad apps
- `file_dialog` example opens iOS document picker

---

## Phase 5: iPad-Specific Polish & App Packaging

**Goal**: Ship-quality iPad experience, deployable to real hardware.

**Duration**: 1 week

### 5.1 — Safe area insets

iPads have rounded corners and (on some models) the home indicator. Content must respect `safeAreaInsets`.

```
In src/platform/ios/window.zig:

Add to Window struct:
  safe_area: struct {
      top: f32,
      bottom: f32,
      left: f32,
      right: f32,
  }

Updated on:
  - viewSafeAreaInsetsDidChange (UIView override)
  - viewWillTransitionToSize:withTransitionCoordinator: (rotation)

Exposed to the layout engine via Cx so apps can use it:
  cx.getSafeArea() → returns the insets

  Alternatively: automatically apply as root padding so existing apps
  just work without any code changes.
```

### 5.2 — Multitasking resize (Split View, Slide Over)

iPadOS apps can be resized by the user via Split View. This is analogous to window resize on macOS. The UIKit callback is `viewWillTransitionToSize:withTransitionCoordinator:`.

```
In src/platform/ios/metal_view.zig:

Register viewWillTransitionToSize:withTransitionCoordinator:
  → calls Window.handleResize(new_width, new_height)
  → existing resize flow handles it (relayout, resize Metal drawable, re-render)

The existing handleResize in macOS window.zig (L618-703) handles:
  - Updating self.size
  - Resizing CAMetalLayer drawable
  - Calling renderer.resize()
  - Calling on_resize callback
  - Re-rendering during resize

Same logic applies on iPad. The renderer.resize() call updates the
Metal drawable size, which is framework-agnostic.
```

### 5.3 — Device rotation

iPad supports all 4 orientations. Handle via `UIViewController.supportedInterfaceOrientations` and the transition coordinator.

```
In src/platform/ios/platform.zig:

UIViewController subclass (GooeyViewController):
  - supportedInterfaceOrientations → all orientations
  - Rotation triggers viewWillTransitionToSize: (handled in 5.2)
  - Content re-layouts automatically via the flexbox engine
```

### 5.4 — App bundle & deployment (Xcode wrapper — primary approach)

The **primary** deployment strategy is an Xcode project that wraps the Zig-built static library. This sidesteps code signing, provisioning profile, and framework linking issues that are difficult to replicate with a shell script alone. It also makes the binary look standard to App Store reviewers.

```
New directory: deploy/ios/

Contents:
  GooeyApp.xcodeproj/     — Minimal Xcode project that:
    - References the Zig-built static library (libgooey.a)
    - Links UIKit, Metal, QuartzCore, CoreText, CoreGraphics frameworks
    - Provides a thin ObjC entry point that calls into Zig
    - Handles code signing, provisioning profiles via Xcode

  GooeyApp/
    AppDelegate.m           — Thin ObjC entry point → calls Zig's gooey_ios_main()
    Info.plist              — Bundle ID, version, device family (iPad), orientations
    LaunchScreen.storyboard — Required by iOS (minimal/empty)
    entitlements.plist      — App Sandbox entitlements

  build-ios.sh            — Convenience script:
    1. Runs zig build -Dtarget=aarch64-ios -Doptimize=ReleaseFast
    2. Runs xcodebuild to produce .app or .ipa
```

### 5.5 — PlatformCapabilities refinements

Update the capabilities struct as features are confirmed working:

```zig
pub const capabilities = PlatformCapabilities{
    .high_dpi = true,
    .multi_window = false,       // Single-scene for now; UIScene multi-window is a follow-up
    .gpu_accelerated = true,
    .display_link = true,
    .can_close_window = false,   // No window chrome
    .glass_effects = false,      // Future: UIBlurEffect
    .clipboard = true,
    .file_dialogs = true,
    .ime = true,
    .custom_cursors = false,     // true when trackpad connected (runtime check)
    .window_drag_by_content = false,
    .name = "iPadOS",
    .graphics_backend = "Metal",
};
```

### Deliverable

- Gooey apps run correctly in Split View / Slide Over
- Device rotation works smoothly
- Content respects safe area insets
- Deployable .app bundle for iPad hardware / TestFlight

---

## Architecture Diagram (After iPad Support)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Layer                            │
│  src/app.zig  ·  src/cx.zig  ·  src/examples/                     │
├─────────────────────────────────────────────────────────────────────┤
│                        Component Layer                              │
│  src/components/  ·  src/widgets/  ·  src/ui/  ·  src/animation/   │
├─────────────────────────────────────────────────────────────────────┤
│                        Context Layer                                │
│  src/context/  ·  src/input/events.zig  ·  src/layout/             │
├─────────────────────────────────────────────────────────────────────┤
│                        Scene Layer                                  │
│  src/scene/  ·  src/platform/unified.zig  ·  src/runtime/          │
├─────────────────────────────────────────────────────────────────────┤
│                   Text / SVG / Image Layer                          │
│  src/text/atlas.zig  ·  src/text/cache.zig  ·  src/svg/atlas.zig  │
│  src/image/atlas.zig                                                │
├──────────────────────┬──────────────────────────────────────────────┤
│    Shared Apple      │                                              │
│  src/platform/apple/ │   (CoreGraphics types shared by both)       │
├────────────┬─────────┴──┬───────────────┬───────────────────────────┤
│   macOS    │    iPad     │    Linux      │         Web              │
│            │    (NEW)    │               │                          │
│  AppKit    │   UIKit     │  Wayland      │  Canvas/DOM              │
│  NSWindow  │   UIWindow  │  wl_surface   │  <canvas>                │
│  NSView    │   UIView    │  wl_shell     │                          │
│            │             │               │                          │
│  CVDisplay │  CADisplay  │  Frame        │  requestAnimation        │
│  Link      │  Link on    │  Callbacks    │  Frame                   │
│  (CV thrd) │  (zig thrd) │               │                          │
│            │             │               │                          │
│  Metal     │  Metal      │  Vulkan       │  WebGPU                  │
│  (shared!) │  (shared!)  │               │                          │
│            │             │               │                          │
│  CoreText  │  CoreText   │  FreeType/    │  Canvas2D                │
│  (shared!) │  (shared!)  │  HarfBuzz     │  measureText             │
│            │             │               │                          │
│  CoreGfx   │  CoreGfx    │  Cairo        │  Canvas2D                │
│  (shared!) │  (shared!)  │  (software)   │  Path2D                  │
│            │             │               │                          │
│  GCD       │  GCD        │  eventfd      │  N/A                     │
│  (shared!) │  (shared!)  │               │                          │
├────────────┴─────────────┴───────────────┴──────────────────────────┤
│                        zig-objc (macOS + iPad)                      │
│                        Objective-C Runtime                          │
└─────────────────────────────────────────────────────────────────────┘
```

## New Files Summary

```
src/platform/apple/
└── core_graphics_types.zig  # CGPoint, CGSize, CGRect — shared by macOS + iOS

src/platform/ios/
├── mod.zig              # Module root — exports types, re-exports shared modules
├── platform.zig         # iOSPlatform — UIApplication lifecycle
├── window.zig           # Window — UIWindow + CAMetalLayer + Metal renderer
├── display_link.zig     # DisplayLink — CADisplayLink on dedicated render thread
├── metal_view.zig       # GooeyMetalView UIView subclass (ObjC class registration)
├── touch_adapter.zig    # Touch → mouse event translation for component compat
├── text_input.zig       # UITextInput protocol, software keyboard management
├── clipboard.zig        # UIPasteboard wrapper
└── file_dialog.zig      # UIDocumentPickerViewController wrapper

deploy/ios/
├── GooeyApp.xcodeproj/  # Minimal Xcode wrapper project
├── GooeyApp/
│   ├── AppDelegate.m         # Thin ObjC entry point → calls Zig static lib
│   ├── Info.plist
│   ├── LaunchScreen.storyboard
│   └── entitlements.plist
└── build-ios.sh         # Convenience: zig build + xcodebuild
```

**Total new files**: 10 source + 6 deploy = 16 files

**Modified files**: 9

| File                             | Change                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| `src/platform/mod.zig`           | Add `is_ios`, `is_apple`, `.ios` backend switch arm                                   |
| `src/platform/macos/appkit.zig`  | Re-export types from `apple/core_graphics_types.zig`                                  |
| `src/platform/macos/window.zig`  | Add `nativeWindowHandle()` / `nativeViewHandle()` methods                             |
| `src/svg/rasterizer.zig`         | Add `.ios` to `.macos` switch arm                                                     |
| `src/svg/mod.zig`                | Change `== .macos` to `is_apple` in backend export                                    |
| `src/image/loader.zig`           | Add `.ios` to `.macos` switch arm                                                     |
| `src/text/types.zig`             | `is_macos` → `is_apple` (enables `CFRelease` on iOS)                                  |
| `src/runtime/window_context.zig` | `is_mac` → `is_apple` (enables Metal atlas uploads on iOS — **critical**)             |
| `src/context/gooey.zig`          | `== .macos` → `is_apple` + use `nativeWindowHandle()`/`nativeViewHandle()` (×4 sites) |
| `src/input/events.zig`           | Add `TouchEvent`, `TouchPhase`, touch variants to `InputEvent` union                  |

**Note**: `src/text/text_system.zig` needs **zero changes** — its `else` branch already selects CoreText for iOS.

## Shared Code Between macOS and iPad

These modules are imported directly (not copied) by the iOS backend:

| Module                      | Path                                                   | Why it works                                                                         |
| --------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| Metal renderer              | `src/platform/macos/metal/` (entire directory)         | Metal API is identical on iOS                                                        |
| GCD dispatcher              | `src/platform/macos/dispatcher.zig`                    | GCD is identical on iOS                                                              |
| Unified primitives          | `src/platform/unified.zig`                             | Platform-agnostic GPU data                                                           |
| Core Graphics types         | `src/platform/apple/core_graphics_types.zig` (**new**) | `CGPoint`/`CGSize`/`CGRect` extracted from `appkit.zig`; macOS re-exports for compat |
| CoreText text backend       | `src/text/backends/coretext/`                          | CoreText API is identical on iOS                                                     |
| CoreGraphics SVG rasterizer | `src/svg/backends/coregraphics.zig`                    | CoreGraphics API is identical on iOS                                                 |
| CoreGraphics image loader   | `src/image/backends/coregraphics.zig`                  | ImageIO/CoreGraphics identical on iOS                                                |

## Risk Register

| Risk                                          | Likelihood | Impact | Mitigation                                                                                                                                                                                                                    |
| --------------------------------------------- | ---------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Zig `aarch64-ios` target maturity             | Medium     | High   | Xcode wrapper is the **primary** strategy (not fallback): Zig builds a static lib, Xcode links it. This isolates Zig from code signing, framework linking, and binary format concerns. Test the static lib output in Phase 1. |
| Code signing complexity                       | Low        | Medium | Handled entirely by Xcode project. Zig never touches provisioning profiles or entitlements.                                                                                                                                   |
| `@cImport` differences for iOS headers        | Low        | Medium | CoreText/CoreGraphics headers are identical. UIKit-specific types use zig-objc runtime calls, not `@cImport`                                                                                                                  |
| CADisplayLink thread model edge cases         | Low        | Medium | Test on real hardware early. CADisplayLink on background thread is a documented Apple pattern                                                                                                                                 |
| App Store review (non-standard binary)        | Low        | Medium | Xcode wrapper makes the binary indistinguishable from a standard Swift/ObjC app to reviewers. Static lib linked by Xcode looks like normal C code.                                                                            |
| ProMotion 120Hz frame pacing                  | Low        | Low    | Same challenge as macOS ProMotion, already handled with CVDisplayLink. Use preferredFrameRateRange on CADisplayLink                                                                                                           |
| Scattered `is_macos` gates missed during port | Medium     | Medium | Mitigated by `is_apple` constant in `platform/mod.zig`. `grep -r 'builtin.os.tag == .macos'` catches all known sites. Sweep in Phase 1.2 and re-check before each phase.                                                      |
| File dialog deadlock on main thread           | Medium     | Medium | Render callbacks run on CADisplayLink thread so semaphore wait should be safe, but must verify no code path calls `promptForPaths` from the main thread. See Phase 4.3.                                                       |

## Resolved Questions

1. **Multi-window on iPad — single-scene first.** iPadOS multi-window via `UISceneDelegate` is complex (scene lifecycle, state restoration, drag-and-drop between scenes). Phase 2 targets a single `UIWindowScene`. The existing `WindowRegistry` and `WindowContext` infrastructure will support multi-scene when we're ready, but it's a follow-up, not a blocker. `PlatformCapabilities.multi_window` is set to `false` for the initial iOS port.

## Open Questions

1. **Apple Pencil**: Support pressure/tilt/azimuth in `TouchEvent`? The struct already has `force`/`max_force`. Pencil adds `altitudeAngle` and `azimuthAngle`. Decision: include in Phase 3 touch event struct but defer gesture handling.

2. **Accessibility on iPad**: macOS accessibility uses `NSAccessibility` protocol. iPadOS uses `UIAccessibility`. The existing `src/accessibility/` module would need a parallel UIKit bridge. **Concrete impact**: the `is_macos` gates in `accessibility.zig` and `mod.zig` should **not** be changed to `is_apple` — they gate `NSAccessibility`-specific code that will fail at runtime on iOS. They need a new `ios_bridge.zig` that implements `UIAccessibility` protocol methods (VoiceOver on iPad). Additionally, `gooey.zig`'s `createPlatformBridge` calls use `window.ns_window`/`window.ns_view` which don't exist on iOS — the `nativeHandle()` accessors (Phase 2.2) solve the field name issue, but the bridge itself needs an iOS-specific implementation. For now, iOS will use the `null_bridge` path (accessibility is a no-op). Real VoiceOver support is a separate effort.

3. **Keyboard shortcuts with hardware keyboard**: iPad Pro with Magic Keyboard supports `⌘C`, `⌘V`, etc. The existing `KeyEvent` and `Modifiers` types in `events.zig` handle this — UIKit delivers `pressesBegan:withEvent:` for hardware key events with the same virtual key codes. Wire this up in Phase 3 as a bonus.

4. **File dialog API divergence**: The synchronous `promptForPaths` API risks deadlock on iOS (see Phase 4.3). Should we introduce a callback-based variant for all platforms, or accept an iOS-only API difference? Recommendation: use the semaphore approach on iOS initially (safe since render callbacks run on the CADisplayLink thread), with a note that a callback-based API could unify all platforms later.
