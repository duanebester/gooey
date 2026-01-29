# Gooey Architecture Refactor — Lite Edition

A focused 5-day refactor addressing the real pain points without over-engineering.

---

## Why This Exists

The full `ARCHITECTURE_REFACTOR.md` is comprehensive but scoped for a larger team/codebase. This lite version extracts the **essential** changes that provide 80% of the benefit in 20% of the time.

**Current codebase:** ~229 files, ~112k lines of Zig

**Problems we're solving:**

1. `core/mod.zig` imports from higher-level modules (violates layering)
2. No compile-time verification that platform backends match interfaces
3. `wgpu/web/` nesting is confusing
4. No mock renderer for testing

**Problems we're NOT solving yet:**

- Formal 5-layer architecture enforcement
- Full platform standardization (`mac/` → `macos/` rename)
- Complete mock suite (FontFace, FileDialog, etc.)
- Module reorganization beyond `core/`

---

## Timeline: 5 Days

| Day | Focus                                | Deliverable                      |
| --- | ------------------------------------ | -------------------------------- |
| 1   | Move files out of `core/`            | Clean module boundaries          |
| 2   | Clean `core/mod.zig`                 | Layer 0 with no upward deps      |
| 3   | Create `interface_verify.zig`        | Compile-time interface contracts |
| 4   | Move `wgpu/web/` to `web/`           | Cleaner platform structure       |
| 5   | Create `MockRenderer` + test helpers | Basic testing infrastructure     |

---

## Day 1: Move Files Out of `core/`

### Goal

`core/` should only contain foundational types with **no internal dependencies**.

### Files to Move

| File                | From    | To       | Reason                                  |
| ------------------- | ------- | -------- | --------------------------------------- |
| `render_bridge.zig` | `core/` | `scene/` | Converts layout→scene, depends on Scene |
| `gradient.zig`      | `core/` | `scene/` | GPU rendering primitive                 |
| `path.zig`          | `core/` | `scene/` | GPU rendering primitive                 |
| `svg.zig`           | `core/` | `scene/` | Scene-level SVG support                 |
| `event.zig`         | `core/` | `input/` | It wraps InputEvent, belongs with input |

### Steps

```bash
# 1. Move files
git mv src/core/render_bridge.zig src/scene/
git mv src/core/gradient.zig src/scene/
git mv src/core/path.zig src/scene/
git mv src/core/svg.zig src/scene/
git mv src/core/event.zig src/input/

# 2. Update imports in moved files
# render_bridge.zig: change "../scene/mod.zig" to "./mod.zig" or direct imports
# event.zig: change "../input/mod.zig" to "./mod.zig" or direct imports

# 3. Update scene/mod.zig to export new files
# 4. Update input/mod.zig to export event types
# 5. Verify build
zig build
```

### Update `scene/mod.zig`

Add these exports:

```zig
// Scene-level rendering utilities
pub const render_bridge = @import("render_bridge.zig");
pub const colorToHsla = render_bridge.colorToHsla;
pub const renderCommandsToScene = render_bridge.renderCommandsToScene;

// Gradients
pub const gradient = @import("gradient.zig");
pub const Gradient = gradient.Gradient;
pub const GradientType = gradient.GradientType;
pub const GradientStop = gradient.GradientStop;
pub const LinearGradient = gradient.LinearGradient;
pub const RadialGradient = gradient.RadialGradient;

// Path building
pub const path = @import("path.zig");
pub const Path = path.Path;
pub const PathCommand = path.Command;
pub const PathError = path.PathError;

// SVG
pub const svg = @import("svg.zig");
```

### Update `input/mod.zig`

Add these exports:

```zig
// Event wrapper (for component event handling)
pub const event = @import("event.zig");
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;
```

### Verification

```bash
# These should return empty (no upward imports from core)
grep -r "@import.*\.\./scene" src/core/
grep -r "@import.*\.\./context" src/core/
grep -r "@import.*\.\./input" src/core/
grep -r "@import.*\.\./debug" src/core/
grep -r "@import.*\.\./animation" src/core/

# Build must pass
zig build
zig build test
```

---

## Day 2: Clean `core/mod.zig`

### Goal

Remove all re-exports that import from higher layers. Keep only:

- `geometry.zig` — local
- `element_types.zig` — local
- `limits.zig` — local
- `triangulator.zig` — local
- `stroke.zig` — local
- `shader.zig` — local

### New `core/mod.zig`

```zig
//! Core primitives for Gooey
//!
//! This module contains foundational types with NO internal dependencies.
//! Higher-level modules (scene, input, context) build on these.
//!
//! For backward compatibility, many types are re-exported from root.zig.

const std = @import("std");

// =============================================================================
// Geometry (platform-agnostic primitives)
// =============================================================================

pub const geometry = @import("geometry.zig");

// Generic types
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const Color = geometry.Color;

// Concrete type aliases
pub const PointF = geometry.PointF;
pub const PointI = geometry.PointI;
pub const SizeF = geometry.SizeF;
pub const SizeI = geometry.SizeI;
pub const RectF = geometry.RectF;
pub const RectI = geometry.RectI;
pub const BoundsF = geometry.BoundsF;
pub const BoundsI = geometry.BoundsI;
pub const EdgesF = geometry.EdgesF;
pub const CornersF = geometry.CornersF;

// GPU-aligned types
pub const GpuPoint = geometry.GpuPoint;
pub const GpuSize = geometry.GpuSize;
pub const GpuBounds = geometry.GpuBounds;
pub const GpuCorners = geometry.GpuCorners;
pub const GpuEdges = geometry.GpuEdges;

// Unit aliases
pub const Pixels = geometry.Pixels;

// =============================================================================
// Element Types
// =============================================================================

pub const element_types = @import("element_types.zig");
pub const ElementId = element_types.ElementId;

// =============================================================================
// Limits (static allocation bounds)
// =============================================================================

pub const limits = @import("limits.zig");

// =============================================================================
// Triangulator
// =============================================================================

pub const triangulator = @import("triangulator.zig");
pub const Triangulator = triangulator.Triangulator;
pub const Vec2 = triangulator.Vec2;
pub const IndexSlice = triangulator.IndexSlice;

// =============================================================================
// Stroke API
// =============================================================================

pub const stroke = @import("stroke.zig");
pub const LineCap = stroke.LineCap;
pub const LineJoin = stroke.LineJoin;
pub const StrokeStyle = stroke.StrokeStyle;
pub const StrokeError = stroke.StrokeError;

// =============================================================================
// Custom Shaders
// =============================================================================

pub const shader = @import("shader.zig");
pub const CustomShader = shader.CustomShader;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
```

### Update `root.zig` for Backward Compatibility

The convenience exports in `root.zig` should now pull from the correct modules:

```zig
// Input events (from input module, not core)
pub const InputEvent = input.InputEvent;
pub const KeyEvent = input.KeyEvent;
// ... etc

// Event system (from input module now)
pub const Event = input.Event;
pub const EventPhase = input.EventPhase;
pub const EventResult = input.EventResult;

// Scene primitives (from scene module, not core)
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
// ... etc

// Render bridge (from scene module now)
pub const render_bridge = scene.render_bridge;

// SVG (from scene module now)
pub const svg = scene.svg;

// Gradient (from scene module now)
pub const Gradient = scene.Gradient;

// Path (from scene module now)
pub const Path = scene.Path;
```

### Expand `limits.zig`

Consolidate all MAX\_\* constants here:

```zig
//! Static allocation limits for Gooey
//!
//! All buffers and pools have fixed upper bounds to eliminate allocation
//! during rendering. If you hit a limit, increase it here and rebuild.

const std = @import("std");

// =============================================================================
// Rendering Limits
// =============================================================================

/// Maximum quads per frame (rectangles, backgrounds)
pub const MAX_QUADS_PER_FRAME = 16384;

/// Maximum glyphs per frame (text characters)
pub const MAX_GLYPHS_PER_FRAME = 65536;

/// Maximum shadows per frame
pub const MAX_SHADOWS_PER_FRAME = 1024;

/// Maximum SVG instances per frame
pub const MAX_SVGS_PER_FRAME = 512;

/// Maximum images per frame
pub const MAX_IMAGES_PER_FRAME = 256;

/// Maximum path instances per frame
pub const MAX_PATHS_PER_FRAME = 4096;

/// Maximum polylines per frame
pub const MAX_POLYLINES_PER_FRAME = 256;

/// Maximum point clouds per frame
pub const MAX_POINT_CLOUDS_PER_FRAME = 64;

/// Maximum clip stack depth (nested clips)
pub const MAX_CLIP_STACK_DEPTH = 32;

// =============================================================================
// Layout Limits
// =============================================================================

/// Maximum layout elements in tree
pub const MAX_LAYOUT_ELEMENTS = 4096;

/// Maximum nested component depth (prevent stack overflow)
pub const MAX_NESTED_COMPONENTS = 64;

/// Maximum render commands per frame
pub const MAX_RENDER_COMMANDS = 8192;

// =============================================================================
// Text Limits
// =============================================================================

/// Maximum glyphs in a single shaped run
pub const MAX_GLYPHS_PER_RUN = 1024;

/// Maximum cached shaped runs
pub const MAX_SHAPED_RUN_CACHE = 256;

/// Maximum text length for single-line inputs
pub const MAX_TEXT_LEN = 512;

// =============================================================================
// Accessibility Limits
// =============================================================================

/// Maximum accessibility tree elements
pub const MAX_A11Y_ELEMENTS = 1024;

/// Maximum pending announcements
pub const MAX_A11Y_ANNOUNCEMENTS = 16;

// =============================================================================
// Widget Limits
// =============================================================================

/// Maximum concurrent widgets
pub const MAX_WIDGETS = 256;

/// Maximum deferred commands per frame
pub const MAX_DEFERRED_COMMANDS = 32;

// =============================================================================
// Window Limits
// =============================================================================

/// Maximum windows per application
pub const MAX_WINDOWS = 8;

// =============================================================================
// Memory Budget Estimates
// =============================================================================

/// Estimated memory for glyph instances (for capacity planning)
pub const GLYPH_INSTANCE_SIZE = 48; // bytes per GlyphInstance
pub const ESTIMATED_GLYPH_MEMORY = MAX_GLYPHS_PER_FRAME * GLYPH_INSTANCE_SIZE;

/// Estimated memory for quads
pub const QUAD_SIZE = 128; // bytes per Quad (with all fields)
pub const ESTIMATED_QUAD_MEMORY = MAX_QUADS_PER_FRAME * QUAD_SIZE;

comptime {
    // Sanity checks - fail compilation if limits are unreasonable
    std.debug.assert(MAX_GLYPHS_PER_FRAME >= MAX_GLYPHS_PER_RUN);
    std.debug.assert(MAX_NESTED_COMPONENTS <= 256); // Stack safety
    std.debug.assert(MAX_CLIP_STACK_DEPTH <= 64); // Reasonable nesting
}
```

### Verification

```bash
zig build
zig build test
# All examples should still compile
```

---

## Day 3: Create Interface Verification

### Goal

Compile-time verification that all platform backends implement consistent APIs.

### Create `core/interface_verify.zig`

```zig
//! Compile-time interface verification
//!
//! Ensures platform backends implement required methods with correct signatures.
//! This provides interface-like guarantees without runtime overhead.
//!
//! Usage in a backend file:
//!   const interface_verify = @import("../../core/interface_verify.zig");
//!   comptime { interface_verify.verifyRendererInterface(@This()); }

const std = @import("std");

/// Verify a type implements the Renderer interface
pub fn verifyRendererInterface(comptime T: type) void {
    comptime {
        // Must have these methods
        assertHasDecl(T, "deinit", "Renderer");
        assertHasDecl(T, "beginFrame", "Renderer");
        assertHasDecl(T, "endFrame", "Renderer");
        assertHasDecl(T, "resize", "Renderer");

        // Must have either renderScene or submitScene
        if (!@hasDecl(T, "renderScene") and !@hasDecl(T, "submitScene")) {
            @compileError("Renderer must have renderScene or submitScene method");
        }
    }
}

/// Verify a type implements the SvgRasterizer interface
pub fn verifySvgRasterizerInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "rasterize", "SvgRasterizer");
    }
}

/// Verify a type implements the ImageLoader interface
pub fn verifyImageLoaderInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "loadFromMemory", "ImageLoader");
    }
}

/// Verify a type implements the Clipboard interface
pub fn verifyClipboardInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "getText", "Clipboard");
        assertHasDecl(T, "setText", "Clipboard");
        assertHasDecl(T, "hasText", "Clipboard");
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn assertHasDecl(comptime T: type, comptime name: []const u8, comptime interface: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} interface requires '{s}' method, but {s} does not have it",
            .{ interface, name, @typeName(T) },
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "interface verification helpers compile" {
    // These are comptime-only, just verify the module compiles
    _ = assertHasDecl;
}
```

### Add Verification to Renderers

**Metal Renderer** (`platform/mac/metal/renderer.zig`):

```zig
const interface_verify = @import("../../../core/interface_verify.zig");

pub const Renderer = struct {
    // ... existing fields and methods ...

    comptime {
        interface_verify.verifyRendererInterface(@This());
    }
};
```

**Vulkan Renderer** (`platform/linux/vulkan_renderer.zig`):

```zig
const interface_verify = @import("../../core/interface_verify.zig");

pub const VulkanRenderer = struct {
    // ... existing fields and methods ...

    comptime {
        interface_verify.verifyRendererInterface(@This());
    }
};
```

**Web Renderer** (`platform/wgpu/web/renderer.zig` or after move: `platform/web/renderer.zig`):

```zig
const interface_verify = @import("../../../core/interface_verify.zig");

pub const WebRenderer = struct {
    // ... existing fields and methods ...

    comptime {
        interface_verify.verifyRendererInterface(@This());
    }
};
```

### Add Verification to SVG Rasterizers

Find all SVG rasterizer implementations and add:

```zig
const interface_verify = @import("../core/interface_verify.zig");

comptime {
    interface_verify.verifySvgRasterizerInterface(@This());
}
```

### Verification

```bash
zig build  # Comptime checks will run automatically
zig build test
```

If any backend is missing a method, you'll get a clear compile error pointing to the missing method.

---

## Day 4: Move `wgpu/web/` to `web/`

### Goal

Flatten the confusing `platform/wgpu/web/` nesting to `platform/web/`.

### Steps

```bash
# 1. Move the directory
git mv src/platform/wgpu/web src/platform/web

# 2. If wgpu/ is now empty or only has shared code, decide:
#    - If empty: git rm -r src/platform/wgpu
#    - If has shared wgpu code: keep it as platform/wgpu/ for shared utilities

# 3. Update imports
```

### Update `platform/mod.zig`

```zig
const std = @import("std");
const builtin = @import("builtin");

// Interface types
pub const interface = @import("interface.zig");
pub const PlatformVTable = interface.PlatformVTable;
pub const WindowVTable = interface.WindowVTable;
pub const WindowOptions = interface.WindowOptions;
pub const PlatformCapabilities = interface.PlatformCapabilities;

// Shared utilities
pub const time = @import("time.zig");
pub const WindowRegistry = @import("window_registry.zig").WindowRegistry;
pub const WindowId = @import("window_registry.zig").WindowId;

// Platform detection
pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

// Backend selection
pub const backend = if (is_wasm)
    @import("web/mod.zig")      // Changed from wgpu/web/mod.zig
else switch (builtin.os.tag) {
    .macos => @import("mac/mod.zig"),
    .linux => @import("linux/mod.zig"),
    else => @compileError("Unsupported platform"),
};

// Re-export active backend types
pub const Platform = backend.Platform;
pub const Window = backend.Window;
pub const capabilities = backend.capabilities;

// Direct access to specific backends (for platform-specific code)
pub const mac = if (is_macos) @import("mac/mod.zig") else struct {};
pub const linux = if (is_linux) @import("linux/mod.zig") else struct {};
pub const web = if (is_wasm) @import("web/mod.zig") else struct {};
```

### Update `platform/time.zig`

Change:

```zig
// Old
const web_imports = @import("wgpu/web/imports.zig");

// New
const web_imports = @import("web/imports.zig");
```

### Update All Internal Imports in `web/`

Files in `platform/web/` that imported from `../wgpu/...` or similar need updating.

### Verification

```bash
zig build -Dtarget=wasm32-freestanding  # or however you build for web
zig build  # native build still works
zig build test
```

---

## Day 5: Create MockRenderer + Test Helpers

### Goal

Enable testing of the layout→render pipeline without real GPU.

### Create `testing/mod.zig`

```zig
//! Testing utilities for Gooey
//!
//! Provides mock implementations and test helpers.
//! Only compiled when running tests.

const std = @import("std");

pub const MockRenderer = @import("mock_renderer.zig").MockRenderer;

// Re-export std testing allocator for convenience
pub const allocator = std.testing.allocator;

// =============================================================================
// Test Helpers
// =============================================================================

const core = @import("../core/mod.zig");

/// Assert two colors are equal (with tolerance for floating point)
pub fn expectColorEqual(expected: core.Color, actual: core.Color) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
    try std.testing.expectApproxEqAbs(expected.a, actual.a, tolerance);
}

/// Assert two bounds are equal (with tolerance)
pub fn expectBoundsEqual(expected: core.BoundsF, actual: core.BoundsF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.origin.x, actual.origin.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.origin.y, actual.origin.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.width, actual.size.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.height, actual.size.height, tolerance);
}

/// Assert two points are equal (with tolerance)
pub fn expectPointEqual(expected: core.PointF, actual: core.PointF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}
```

### Create `testing/mock_renderer.zig`

```zig
//! Mock renderer for testing
//!
//! Tracks method calls without actual GPU operations.

const std = @import("std");
const interface_verify = @import("../core/interface_verify.zig");

pub const MockRenderer = struct {
    // Call tracking
    begin_frame_count: u32 = 0,
    end_frame_count: u32 = 0,
    render_scene_count: u32 = 0,
    resize_count: u32 = 0,

    // Last values
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_scale: f32 = 1.0,

    // Control behavior
    should_fail_begin_frame: bool = false,

    const Self = @This();

    pub fn init(_: std.mem.Allocator) !Self {
        return Self{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn beginFrame(self: *Self, width: u32, height: u32, scale: f32) !void {
        if (self.should_fail_begin_frame) {
            return error.MockFailure;
        }
        self.begin_frame_count += 1;
        self.last_width = width;
        self.last_height = height;
        self.last_scale = scale;
    }

    pub fn endFrame(self: *Self) void {
        self.end_frame_count += 1;
    }

    pub fn renderScene(self: *Self, _: anytype) void {
        self.render_scene_count += 1;
    }

    pub fn resize(self: *Self, width: u32, height: u32) void {
        self.resize_count += 1;
        self.last_width = width;
        self.last_height = height;
    }

    /// Reset all counters (for test isolation)
    pub fn reset(self: *Self) void {
        self.begin_frame_count = 0;
        self.end_frame_count = 0;
        self.render_scene_count = 0;
        self.resize_count = 0;
        self.should_fail_begin_frame = false;
    }

    // Verify we implement the interface
    comptime {
        interface_verify.verifyRendererInterface(@This());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MockRenderer tracks calls" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    try renderer.beginFrame(800, 600, 2.0);
    renderer.endFrame();

    try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
    try std.testing.expectEqual(@as(u32, 1), renderer.end_frame_count);
    try std.testing.expectEqual(@as(u32, 800), renderer.last_width);
    try std.testing.expectEqual(@as(u32, 600), renderer.last_height);
    try std.testing.expectEqual(@as(f32, 2.0), renderer.last_scale);
}

test "MockRenderer can simulate failure" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    renderer.should_fail_begin_frame = true;
    try std.testing.expectError(error.MockFailure, renderer.beginFrame(800, 600, 1.0));
}
```

### Add to `root.zig`

```zig
// Testing utilities (only available in test builds)
pub const testing = if (@import("builtin").is_test)
    @import("testing/mod.zig")
else
    struct {};
```

### Create Directory Structure

```bash
mkdir -p src/testing
# Create the files above
```

### Verification

```bash
zig build test
```

---

## Checklist

### Day 1: Move Files ✅

- [x] Move `render_bridge.zig` to `scene/`
- [x] Move `gradient.zig` to `scene/`
- [x] Move `path.zig` to `scene/`
- [x] Move `svg.zig` to `scene/`
- [x] Move `event.zig` to `input/`
- [x] Update `scene/mod.zig` exports
- [x] Update `input/mod.zig` exports
- [x] Fix any broken imports in moved files
- [x] `zig build` passes

### Day 2: Clean core/mod.zig ✅

- [x] Remove all re-exports from higher layers
- [x] Update `root.zig` backward-compat exports
- [x] Expand `limits.zig` with all MAX\_\* constants
- [x] Verify: `grep -r "@import.*\.\./scene" src/core/` returns empty
- [x] Verify: `grep -r "@import.*\.\./context" src/core/` returns empty
- [x] `zig build` passes
- [x] `zig build test` passes

### Day 3: Interface Verification ✅

- [x] Create `core/interface_verify.zig`
- [x] Add verification to Metal renderer
- [x] Add verification to Vulkan renderer
- [x] Add verification to Web renderer
- [x] Add verification to SVG rasterizers
- [x] Add verification to Linux Clipboard
- [x] Export from `core/mod.zig`
- [x] `zig build` passes (comptime checks run)
- [x] `zig build -Dtarget=wasm32-freestanding` passes
- [x] `zig build test` passes

### Day 4: Flatten web/ ✅

- [x] Move `platform/wgpu/web/` to `platform/web/`
- [x] Update `platform/mod.zig`
- [x] Update `platform/time.zig`
- [x] Update any other imports
- [x] `zig build` passes (all targets)

### Day 5: Testing Infrastructure ✅

- [x] Create `testing/mod.zig`
- [x] Create `testing/mock_renderer.zig`
- [x] Add test helpers
- [x] Add `testing` export to `root.zig`
- [x] `zig build test` passes

---

## What We're NOT Doing (Deferred)

These items from the full refactor are explicitly deferred:

1. **Renaming `mac/` → `macos/`** — cosmetic, no real benefit
2. **Full 5-layer architecture enforcement** — overkill for current team size
3. **MockFontFace, MockClipboard, MockFileDialog, MockSvgRasterizer** — add when needed
4. **Reorganizing `svg/` with backends/** — current structure works
5. **`accessibility/mod.zig` creation** — current structure works
6. **Platform capabilities struct standardization** — premature

When to revisit: when you have 2+ regular contributors, or when you're preparing for a 1.0 release.

---

## Rollback

Each day is independent. If something breaks:

```bash
git stash  # or git reset --hard HEAD
```

Re-assess and try a smaller change.
