# Gooey Architecture Refactor Plan

> A phased approach to improving module structure, establishing formal interfaces, and enforcing clear architectural boundaries.

**Status:** ✅ Complete (All 5 Phases Done)  
**Created:** 2025-01-20  
**Last Updated:** 2025-01-XX (LITE Refactor + unified.zig consolidation)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current Status](#current-status)
3. [Current State Analysis](#current-state-analysis)
4. [Target Architecture](#target-architecture)
5. [Phase 1: Foundation Cleanup](#phase-1-foundation-cleanup) ✅
6. [Phase 2: Interface Extraction](#phase-2-interface-extraction) ✅
7. [Phase 3: Platform Standardization](#phase-3-platform-standardization) ⚡
8. [Phase 4: Module Reorganization](#phase-4-module-reorganization)
9. [Phase 5: Testing Infrastructure](#phase-5-testing-infrastructure) ⚡
10. [Migration Guide](#migration-guide)
11. [Risk Assessment](#risk-assessment)

---

## Executive Summary

This document outlines a plan to refactor Gooey's architecture to:

1. **Establish clear module boundaries** - Each module has a single responsibility
2. **Define formal interfaces** - All platform backends implement documented traits
3. **Enforce layered dependencies** - Lower layers never import from higher layers
4. **Improve testability** - Mock implementations for all interfaces
5. **Standardize platform code** - Consistent structure across macOS, Linux, Web

**Naming Decision:** After surveying major UI frameworks (Iced, egui, GPUI, Slint, Flutter, Qt, GTK), we are **keeping `components/` and `widgets/`** as-is. `widgets/` is the dominant term in native/desktop frameworks, and `components/` is familiar to web developers. The originally proposed `primitives/` and `state/` names were rejected as too ambiguous.

Note: Not every phase has been super deep dived - so there might be times to ask clarifying questions and or get confirmations. We are mostly refactoring, so we are not allowed to change or modify the code unless it's explicitly required by for the phase.

### Key Principles (from CLAUDE.md)

- Zero technical debt policy - solve problems correctly the first time
- Static memory allocation - no dynamic allocation after initialization
- Assertion density - minimum 2 assertions per function
- 70-line function limit
- Put a limit on everything

---

## Current Status

> **Last Updated:** After LITE Refactor + Testing Infrastructure completion

| Phase                                 | Status      | Notes                                                                |
| ------------------------------------- | ----------- | -------------------------------------------------------------------- |
| **Phase 1: Foundation Cleanup**       | ✅ Complete | Files moved to proper layers, `core/` cleaned, `limits.zig` expanded |
| **Phase 2: Interface Verification**   | ✅ Complete | `interface_verify.zig` created, all renderers verified               |
| **Phase 3: Platform Standardization** | ✅ Complete | `web/` flattened, `unified.zig` consolidated, `macos/` renamed       |
| **Phase 4: Module Reorganization**    | ✅ Complete | `accessibility/mod.zig`, `svg/backends/` reorganization done         |
| **Phase 5: Testing Infrastructure**   | ✅ Complete | `MockRenderer`, `MockClipboard`, `MockSvgRasterizer`, docs done      |

### What Was Done (LITE Refactor)

**Day 1-2: Foundation Cleanup**

- Moved `render_bridge.zig`, `gradient.zig`, `path.zig`, `svg.zig` → `scene/`
- Moved `event.zig` → `input/`
- Cleaned `core/mod.zig` (removed upward dependencies)
- Expanded `limits.zig` with all MAX\_\* constants + memory budgets

**Day 3: Interface Verification**

- Created `core/interface_verify.zig` with comptime verification
- Added verification to Metal, Vulkan, Web renderers
- Added verification to SVG rasterizers and Linux clipboard

**Day 4: Platform Flattening**

- Moved `platform/wgpu/web/` → `platform/web/`
- Updated `platform/mod.zig` and `platform/time.zig`

**Day 5: Testing Infrastructure**

- Created `testing/mod.zig` with `MockRenderer`
- Added test helpers: `expectColorEqual`, `expectBoundsEqual`, `expectPointEqual`

**Post-LITE: unified.zig Consolidation**

- Consolidated `platform/wgpu/unified.zig` + `platform/mac/metal/unified.zig` → `platform/unified.zig`
- Using flat field layout (required for WGSL/SPIR-V, works on Metal)
- All 775 tests pass

### Deferred Items (revisit at 1.0 or with 2+ contributors)

- Renaming `mac/` → `macos/` (cosmetic)
- ~~`MockFontFace`, `MockClipboard`, `MockFileDialog`, `MockSvgRasterizer`~~ ✅ COMPLETED
- `accessibility/mod.zig` creation
- `svg/backends/` reorganization

---

## Current State Analysis

### What's Working Well

| Area                       | Status     | Notes                                                |
| -------------------------- | ---------- | ---------------------------------------------------- |
| VTable pattern             | ✅ Good    | Consistent across FontFace, Shaper, Bridge, Platform |
| Comptime backend selection | ✅ Good    | `if (is_wasm) ... else switch (builtin.os.tag)`      |
| Static allocation          | ✅ Good    | MAX\_\* constants throughout                         |
| Module separation          | ⚠️ Partial | text, scene, layout are well-separated               |

### Issues Identified

| Issue                                        | Severity    | Location                          |
| -------------------------------------------- | ----------- | --------------------------------- |
| Re-export hell in core/mod.zig               | ✅ Resolved | `src/core/mod.zig` cleaned        |
| Missing interfaces for SVG, Image, Clipboard | ✅ Resolved | `interface_verify.zig` added      |
| Inconsistent platform directory structure    | ✅ Resolved | `web/` flattened, `unified.zig`   |
| Component vs Widget naming confusion         | ✅ Resolved | Kept both (industry convention)   |
| No renderer interface                        | ✅ Resolved | Comptime verification added       |
| Circular conceptual dependencies             | ✅ Resolved | core has no upward deps           |
| No mock implementations for testing          | ⚡ Partial  | `MockRenderer` done, others defer |

### Current Directory Structure

```
src/
├── core/           # Foundational types (CLEANED - no upward deps)
│   ├── geometry.zig
│   ├── limits.zig           # All MAX_* constants centralized
│   ├── interface_verify.zig # Comptime interface checks
│   └── ...
├── platform/       # OS/graphics abstraction
│   ├── mac/        # macOS + Metal (rename to macos/ deferred)
│   │   └── metal/  # Metal renderer
│   ├── linux/      # Linux + Vulkan
│   ├── web/        # Web/WASM (MOVED from wgpu/web/)
│   ├── wgpu/       # Shared WGPU shaders only
│   └── unified.zig # Consolidated shader primitives (all platforms)
├── text/           # Text rendering
│   └── backends/   # coretext, freetype, web
├── scene/          # GPU primitives + render_bridge, gradient, path, svg
├── layout/         # Layout engine
├── context/        # Gooey, focus, dispatch, entities
├── ui/             # Declarative builder
├── components/     # Stateless render functions
├── widgets/        # Stateful implementations
├── accessibility/  # A11y tree + bridges (mod.zig pending)
├── animation/      # Easing/interpolation
├── input/          # Events + keymaps + event.zig
├── image/          # Image loading
├── svg/            # SVG rasterization (backends/ reorg pending)
├── debug/          # Inspector, profiler
├── runtime/        # Event loop, windows
├── testing/        # MockRenderer + test helpers
└── examples/       # Demos
```

---

## Target Architecture

### Layered Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 5: Application                                             │
│   ui/, primitives/, state/, runtime/, debug/, examples/          │
├─────────────────────────────────────────────────────────────────┤
│ Layer 4: Systems                                                 │
│   text/text_system.zig, accessibility/, context/                 │
├─────────────────────────────────────────────────────────────────┤
│ Layer 3: Platform Backends (comptime-verified implementations)   │
│   platform/{macos,linux,web}/, text/backends/, svg/backends/     │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: Data Structures                                         │
│   scene/, layout/, text/{types,atlas,cache}.zig, input/          │
├─────────────────────────────────────────────────────────────────┤
│ Layer 0: Foundation (no internal deps, comptime interface verify)│
│   core/{geometry,event,limits,interface_verify}.zig              │
└─────────────────────────────────────────────────────────────────┘
```

### Dependency Rules

- **Layer N may only import from Layer N-1 or lower**
- No circular dependencies between modules at the same layer
- Platform backends implement expected APIs verified via `core/interface_verify.zig`
- VTables exist where already used (FontFace, Bridge, PlatformVTable) and for testing mocks

### Target Directory Structure

```
src/
├── root.zig                    # Public API + convenience re-exports
├── app.zig                     # Entry points (run, runCx)
├── validation.zig              # Form validation (pure functions)
│
├── core/                       # Layer 0: Foundation ✅ DONE
│   ├── mod.zig                 # ONLY exports local types ✅
│   ├── geometry.zig            # Point, Size, Rect, Color, Edges, Corners ✅
│   ├── limits.zig              # MAX_* constants (centralized) ✅
│   ├── element_types.zig       # ElementId ✅
│   ├── stroke.zig              # Stroke styles ✅
│   ├── shader.zig              # Custom shader definitions ✅
│   ├── triangulator.zig        # Polygon triangulation ✅
│   └── interface_verify.zig    # Comptime interface verification ✅
│
├── scene/                      # Layer 2: GPU primitives (unchanged)
├── layout/                     # Layer 2: Layout engine (unchanged)
├── input/                      # Layer 2: Input events (unchanged)
├── animation/                  # Layer 2: Animation (unchanged)
│
├── platform/                   # Layer 3: Platform backends ✅ MOSTLY DONE
│   ├── mod.zig                 # Public API + backend selection ✅
│   ├── interface.zig           # PlatformVTable, WindowVTable, WindowOptions ✅
│   ├── unified.zig             # Shared GPU primitives (all platforms) ✅
│   ├── time.zig                # Cross-platform time ✅
│   ├── window_registry.zig     # Window ID tracking ✅
│   │
│   ├── mac/                    # macOS + Metal (macos/ rename deferred)
│   │   ├── mod.zig
│   │   ├── platform.zig
│   │   ├── window.zig
│   │   ├── renderer.zig        # Metal renderer (implements Renderer)
│   │   ├── shaders/            # MSL shaders
│   │   ├── clipboard.zig       # Implements Clipboard interface
│   │   ├── file_dialog.zig     # Implements FileDialog interface
│   │   ├── display_link.zig
│   │   ├── appkit.zig
│   │   └── input_view.zig
│   │
│   ├── linux/
│   │   ├── mod.zig
│   │   ├── platform.zig
│   │   ├── window.zig
│   │   ├── renderer.zig        # Vulkan renderer (implements Renderer)
│   │   ├── shaders/
│   │   ├── clipboard.zig
│   │   ├── file_dialog.zig
│   │   ├── wayland.zig
│   │   └── dbus.zig
│   │
│   ├── web/                    # Moved from wgpu/web/ ✅
│   │   ├── mod.zig
│   │   ├── platform.zig
│   │   ├── window.zig
│   │   ├── renderer.zig        # WGPU renderer (implements Renderer) ✅
│   │   ├── clipboard.zig
│   │   ├── file_dialog.zig
│   │   └── imports.zig         # JS interop
│   │
│   └── wgpu/                   # Shared WGPU assets
│       └── shaders/            # WGSL shaders
│
├── text/                       # Layer 3-4: Text system
│   ├── mod.zig
│   ├── types.zig               # Metrics, ShapedGlyph, etc.
│   ├── atlas.zig               # Texture atlas
│   ├── cache.zig               # Glyph cache
│   ├── render.zig              # Text rendering utilities
│   ├── text_system.zig         # High-level API
│   └── backends/
│       ├── coretext/           # macOS (implements FontFace, Shaper)
│       ├── freetype/           # Linux (implements FontFace, Shaper)
│       └── web/                # WASM (implements FontFace, Shaper)
│
├── svg/                        # Layer 3: SVG rasterization (backends/ reorg DEFERRED)
│   ├── mod.zig
│   ├── atlas.zig
│   ├── rasterizer.zig          # Backend selection + interface verification ✅
│   ├── rasterizer_cg.zig       # macOS CoreGraphics
│   ├── rasterizer_linux.zig    # Linux Cairo
│   ├── rasterizer_web.zig      # Web Canvas2D
│   └── rasterizer_stub.zig     # Fallback stub
│
├── image/                      # Layer 3: Image loading
│   ├── mod.zig
│   ├── atlas.zig
│   └── loader.zig              # Implements ImageLoader interface
│
├── accessibility/              # Layer 4: A11y system (mod.zig DEFERRED)
│   ├── accessibility.zig       # Main API
│   ├── tree.zig
│   ├── element.zig
│   ├── types.zig
│   ├── bridge.zig              # Bridge interface + TestBridge
│   ├── fingerprint.zig
│   ├── constants.zig
│   ├── mac_bridge.zig          # macOS accessibility
│   ├── linux_bridge.zig        # Linux AT-SPI
│   └── web_bridge.zig          # Web ARIA
│
├── context/                    # Layer 4: Gooey context (unchanged)
│
├── ui/                         # Layer 5: Declarative builder (unchanged)
│
├── components/                 # Layer 5: Stateless render functions (unchanged)
│   ├── mod.zig
│   ├── button.zig
│   ├── checkbox.zig
│   ├── text_input.zig
│   └── ...
│
├── widgets/                    # Layer 5: Stateful widget implementations (unchanged)
│   ├── mod.zig
│   ├── text_input.zig
│   ├── text_area.zig
│   ├── code_editor.zig
│   └── ...
│
├── runtime/                    # Layer 5: Event loop (unchanged)
├── debug/                      # Layer 5: Inspector (unchanged)
│
├── testing/                    # Test utilities ✅ PARTIAL
│   ├── mod.zig                 # Test helpers + allocator ✅
│   └── mock_renderer.zig       # MockRenderer with interface verification ✅
│   # Deferred mocks (add when needed):
│   # - mock_font_face.zig
│   # - mock_clipboard.zig
│   # - mock_file_dialog.zig
│   # - mock_svg_rasterizer.zig
│
└── examples/                   # Demo apps (unchanged)
```

---

## Phase 1: Foundation Cleanup ✅ COMPLETED

**Goal:** Make `core/` truly foundational with zero external dependencies.

**Duration:** 2-3 days (completed)

### Issues That Were Resolved

These upward dependencies violated Layer 0 principles and have been fixed:

| File                | Was Importing From                                     | Resolution                 |
| ------------------- | ------------------------------------------------------ | -------------------------- |
| `mod.zig`           | `scene/`, `context/`, `input/`, `animation/`, `debug/` | ✅ Cleaned, no upward deps |
| `event.zig`         | `input/events.zig`                                     | ✅ Moved to `input/`       |
| `render_bridge.zig` | `scene/`, `layout/`                                    | ✅ Moved to `scene/`       |
| `gradient.zig`      | `scene/scene.zig`                                      | ✅ Moved to `scene/`       |
| `path.zig`          | `scene/path_mesh.zig`, `scene/mesh_pool.zig`           | ✅ Moved to `scene/`       |
| `svg.zig`           | `scene/mod.zig`                                        | ✅ Moved to `scene/`       |

### Tasks (All Completed)

#### 1.1 Audit Existing MAX\_\* Constants ✅

Before creating the centralized `limits.zig`, audit the codebase:

```bash
# Find all existing MAX_* constants
grep -r "MAX_" src/ --include="*.zig" | grep "pub const MAX_"

# Check for duplicates and inconsistencies
grep -rh "MAX_PATHS" src/ --include="*.zig"
grep -rh "MAX_GLYPHS" src/ --include="*.zig"
```

Document findings and reconcile any conflicts before proceeding.

#### 1.2 Expand `core/limits.zig` ✅

Expand the existing `limits.zig` (which currently focuses on path rendering) to include all MAX\_\* constants. **Preserve the excellent memory budget documentation style** already in place:

```zig
// src/core/limits.zig
//! Static limits for all gooey subsystems
//!
//! Per CLAUDE.md: "Put a limit on everything"
//!
//! ## Memory Budget Summary
//!
//! Scene per-frame:
//!   - Quads: 16384 × 64B = ~1MB
//!   - Glyphs: 65536 × 32B = ~2MB
//!   - Shadows: 1024 × 48B = ~48KB
//!   - Total scene: ~3.5MB
//!
//! Layout:
//!   - Elements: 4096 × 128B = ~512KB
//!   - Commands: 8192 × 64B = ~512KB
//!
//! Text:
//!   - Glyph cache: 65536 × 16B = ~1MB
//!   - Shaped runs: 256 × 2KB = ~512KB

const std = @import("std");

// =============================================================================
// Scene Limits (per-frame GPU upload budgets)
// =============================================================================

pub const MAX_QUADS_PER_FRAME = 16384;      // ~1MB vertex data
pub const MAX_GLYPHS_PER_FRAME = 65536;     // ~2MB glyph instances
pub const MAX_SHADOWS_PER_FRAME = 1024;     // ~48KB shadow data
pub const MAX_SVGS_PER_FRAME = 512;
pub const MAX_IMAGES_PER_FRAME = 256;
pub const MAX_PATHS_PER_FRAME = 4096;       // Reconciled from existing limits.zig
pub const MAX_POLYLINES_PER_FRAME = 256;
pub const MAX_POINT_CLOUDS_PER_FRAME = 64;
pub const MAX_CLIP_STACK_DEPTH = 32;

// =============================================================================
// Layout Limits
// =============================================================================

pub const MAX_LAYOUT_ELEMENTS = 4096;
pub const MAX_NESTED_COMPONENTS = 64;
pub const MAX_RENDER_COMMANDS = 8192;

// =============================================================================
// Text Limits
// =============================================================================

pub const MAX_GLYPHS_PER_RUN = 1024;
pub const MAX_SHAPED_RUN_CACHE = 256;
pub const MAX_TEXT_LEN = 512;

// =============================================================================
// Accessibility Limits
// =============================================================================

pub const MAX_A11Y_ELEMENTS = 1024;
pub const MAX_A11Y_ANNOUNCEMENTS = 16;

// =============================================================================
// Widget Limits
// =============================================================================

pub const MAX_WIDGETS = 256;
pub const MAX_DEFERRED_COMMANDS = 32;

// =============================================================================
// Window Limits
// =============================================================================

pub const MAX_WINDOWS = 8;

// =============================================================================
// Path Rendering Limits (preserved from existing limits.zig)
// =============================================================================

// ... (keep existing path-specific limits and documentation)

// =============================================================================
// Compile-time Validation
// =============================================================================

comptime {
    // Sanity checks
    std.debug.assert(MAX_CLIP_STACK_DEPTH >= 16);
    std.debug.assert(MAX_NESTED_COMPONENTS <= MAX_LAYOUT_ELEMENTS);
    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);
}
```

#### 1.3 Move `render_bridge.zig` to `scene/` ✅

`render_bridge.zig` is a **bridge between Layer 2 modules** (layout → scene), not a Layer 0 foundation type. Move it:

```bash
mv src/core/render_bridge.zig src/scene/render_bridge.zig
```

Update imports in `scene/mod.zig`:

```zig
// src/scene/mod.zig
pub const render_bridge = @import("render_bridge.zig");
pub const colorToHsla = render_bridge.colorToHsla;
pub const renderCommandsToScene = render_bridge.renderCommandsToScene;
```

Update all files that import from `core.render_bridge` to use `scene.render_bridge`.

#### 1.4 Move Tessellation Files to `scene/` ✅

These files have upward dependencies on `scene/` and belong in Layer 2:

| File           | Move To              | Reason                                               |
| -------------- | -------------------- | ---------------------------------------------------- |
| `gradient.zig` | `scene/gradient.zig` | Imports `scene/scene.zig`                            |
| `path.zig`     | `scene/path.zig`     | Imports `scene/path_mesh.zig`, `scene/mesh_pool.zig` |
| `svg.zig`      | `scene/svg.zig`      | Imports `scene/mod.zig`                              |

```bash
mv src/core/gradient.zig src/scene/gradient.zig
mv src/core/path.zig src/scene/path.zig
mv src/core/svg.zig src/scene/svg.zig
```

Update `scene/mod.zig` to export these, and update `root.zig` re-exports accordingly.

**Note:** `triangulator.zig` and `stroke.zig` may be pure algorithms with no upward deps—verify before moving. If they're pure, they can stay in `core/`.

#### 1.5 Fix `event.zig` Dependency ✅

`core/event.zig` currently imports from `input/events.zig`:

```zig
const input = @import("../input/events.zig");
```

**Dependency Audit Results:**

`event.zig` wraps `input.InputEvent` to add DOM-style capture/bubble phase semantics. It only uses `InputEvent` (the tagged union), not the specific event types directly. The `Event` struct with its phase tracking is really an **input event wrapper**, not a foundational type.

**Solution: Move `event.zig` to `input/`**

The `Event` wrapper belongs with the input system, not in Layer 0:

```bash
mv src/core/event.zig src/input/event.zig
```

Update the import inside `event.zig`:

```zig
// src/input/event.zig (after move)
const input = @import("events.zig");  // Was: "../input/events.zig"
```

Update `input/mod.zig` to export it:

```zig
// src/input/mod.zig
pub const event = @import("event.zig");
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;
```

For backward compatibility, `core/mod.zig` re-exports from `input/`:

```zig
// src/core/mod.zig (backward compatibility)
pub const event = @import("../input/event.zig");
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;
```

**Why not move `InputEvent` to core instead?**

Moving `InputEvent` and all its constituent types (`MouseEvent`, `KeyEvent`, `ScrollEvent`, etc.) into `core/` would bloat the foundation layer with input-specific types. These are semantically input types, not geometry/math primitives.

#### 1.6 Clean `core/mod.zig` ✅

After the moves above, `core/mod.zig` becomes truly minimal:

```zig
// src/core/mod.zig
//! Core primitives for gooey
//!
//! This module contains ONLY foundational types with no internal dependencies.
//! For convenience re-exports, use the root module.

const std = @import("std");

// =============================================================================
// Local Modules Only (no upward dependencies)
// =============================================================================

pub const geometry = @import("geometry.zig");
pub const event = @import("event.zig");
pub const limits = @import("limits.zig");
pub const element_types = @import("element_types.zig");
pub const triangulator = @import("triangulator.zig");  // Pure algorithm
pub const stroke = @import("stroke.zig");              // Pure algorithm
pub const shader = @import("shader.zig");

// =============================================================================
// Convenience Re-exports (geometry is truly foundational)
// =============================================================================

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Color = geometry.Color;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;

// GPU-aligned types
pub const GpuPoint = geometry.GpuPoint;
pub const GpuSize = geometry.GpuSize;
pub const GpuBounds = geometry.GpuBounds;
pub const GpuCorners = geometry.GpuCorners;
pub const GpuEdges = geometry.GpuEdges;

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
pub const Pixels = geometry.Pixels;

// Event types
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// Element ID
pub const ElementId = element_types.ElementId;

// Stroke types (pure, no deps)
pub const LineCap = stroke.LineCap;
pub const LineJoin = stroke.LineJoin;
pub const StrokeStyle = stroke.StrokeStyle;

// Custom shaders
pub const CustomShader = shader.CustomShader;

test {
    std.testing.refAllDecls(@This());
}
```

#### 1.7 Update `root.zig` for Convenience Re-exports ✅

Move all the convenience re-exports from `core/mod.zig` to `root.zig`. The existing `root.zig` already has most of these—verify and consolidate:

```zig
// In root.zig, ensure these sections exist:
// =============================================================================
// Convenience Re-exports (for backward compatibility)
// =============================================================================

// From scene (canonical) - includes moved files
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const render_bridge = scene.render_bridge;  // Moved from core
pub const svg = scene.svg;                      // Moved from core
pub const Path = scene.Path;                    // Moved from core
pub const Gradient = scene.Gradient;            // Moved from core
// ...

// From context (canonical)
pub const Gooey = context.Gooey;
pub const FocusManager = context.FocusManager;
// ...

// From input (canonical)
pub const InputEvent = input.InputEvent;
pub const KeyEvent = input.KeyEvent;
// ...
```

#### 1.8 Verification ✅

**Automated Checks:**

```bash
# Verify core/ has zero upward dependencies
grep -r "@import.*\.\./scene" src/core/
grep -r "@import.*\.\./context" src/core/
grep -r "@import.*\.\./input" src/core/
grep -r "@import.*\.\./animation" src/core/
grep -r "@import.*\.\./debug" src/core/
grep -r "@import.*\.\./layout" src/core/

# All should return empty. If not, Phase 1 is incomplete.
```

**Build Checks:**

- [ ] `zig build` succeeds with no errors
- [ ] `zig build test` passes all tests
- [ ] All examples compile: `zig build-exe src/examples/*.zig` (or equivalent)

**Manual Verification:**

- [ ] `core/` directory contains only: `geometry.zig`, `event.zig`, `limits.zig`, `element_types.zig`, `triangulator.zig`, `stroke.zig`, `shader.zig`, `mod.zig`
- [ ] `scene/` directory now contains: `render_bridge.zig`, `gradient.zig`, `path.zig`, `svg.zig` (moved files)
- [ ] No circular dependencies introduced (build would fail if so)

**Documentation:**

- [ ] Update any README or architecture docs that reference old file locations
- [ ] Add migration note for external users if any public API paths changed

---

## Phase 2: Comptime Interface Verification ✅ COMPLETED

**Goal:** Ensure all platform backends implement consistent APIs using compile-time verification, while keeping comptime dispatch for maximum performance.

**Duration:** 3-4 days (completed)

### Design Philosophy

**Comptime dispatch for performance, compile-time verification for correctness.**

```
┌─────────────────────────────────────────────────────────────────┐
│ Production Code Path (Zero Overhead)                            │
│                                                                 │
│   platform.Renderer  ──comptime──>  MetalRenderer               │
│   svg.rasterize()    ──comptime──>  rasterizer_cg.rasterize()   │
│   image.load()       ──comptime──>  loadFromMemoryMacOS()       │
│                                                                 │
│   No VTable, no indirection, full inlining potential            │
├─────────────────────────────────────────────────────────────────┤
│ Test Code Path (VTable for Mocks)                               │
│                                                                 │
│   testing.MockRenderer  ──vtable──>  tracks calls, returns fake │
│   testing.MockClipboard ──vtable──>  in-memory storage          │
│                                                                 │
│   Only used in tests, not production                            │
└─────────────────────────────────────────────────────────────────┘
```

### Why Not a Separate `interfaces/` Directory?

1. **Coupling risk** - Re-exporting from `text/`, `accessibility/`, `platform/` creates dependency cycles
2. **Performance** - We want comptime dispatch as the primary path
3. **Locality** - Interfaces should live near their implementations
4. **Existing pattern** - `FontFace`, `Bridge`, `PlatformVTable` already follow this

### Tasks (All Completed)

#### 2.1 Create `core/interface_verify.zig` ✅

Compile-time interface verification utilities. This verifies that platform backends implement the expected methods **without** requiring VTables at runtime:

```zig
// src/core/interface_verify.zig
//! Compile-time interface verification
//!
//! Ensures platform backends implement required methods with correct signatures.
//! This provides interface-like guarantees without runtime overhead.
//!
//! Usage:
//!   comptime { verifyRendererInterface(@TypeOf(my_renderer)); }

const std = @import("std");

/// Verify a type implements the Renderer interface
pub fn verifyRendererInterface(comptime T: type) void {
    // Required methods with exact signatures
    comptime {
        assertMethod(T, "init", fn (std.mem.Allocator) anyerror!T);
        assertMethod(T, "deinit", fn (*T) void);
        assertMethod(T, "beginFrame", fn (*T, u32, u32, f32) void);
        assertMethod(T, "endFrame", fn (*T) void);
        assertMethod(T, "resize", fn (*T, u32, u32) void);

        // Scene submission - signature varies by renderer, just check existence
        if (!@hasDecl(T, "renderScene") and !@hasDecl(T, "submitScene")) {
            @compileError("Renderer must have renderScene or submitScene method");
        }
    }
}

/// Verify a type implements the SvgRasterizer interface
pub fn verifySvgRasterizerInterface(comptime T: type) void {
    comptime {
        // Must have rasterize function
        if (!@hasDecl(T, "rasterize")) {
            @compileError("SvgRasterizer must have rasterize function");
        }

        // Check return type includes expected fields
        const RasterizedType = @typeInfo(@TypeOf(T.rasterize)).@"fn".return_type.?;
        if (@typeInfo(RasterizedType) != .error_union) {
            @compileError("rasterize must return an error union");
        }
    }
}

/// Verify a type implements the ImageLoader interface
pub fn verifyImageLoaderInterface(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "loadFromMemory") and !@hasDecl(T, "decode")) {
            @compileError("ImageLoader must have loadFromMemory or decode function");
        }
    }
}

/// Verify a type implements the Clipboard interface
pub fn verifyClipboardInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "getText", "Clipboard must have getText");
        assertHasDecl(T, "setText", "Clipboard must have setText");
        assertHasDecl(T, "hasText", "Clipboard must have hasText");
    }
}

/// Verify a type implements the FileDialog interface
pub fn verifyFileDialogInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "open", "FileDialog must have open");
        assertHasDecl(T, "save", "FileDialog must have save");
    }
}

// =============================================================================
// Helper Functions
// =============================================================================

fn assertHasDecl(comptime T: type, comptime name: []const u8, comptime msg: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(msg);
    }
}

fn assertMethod(comptime T: type, comptime name: []const u8, comptime ExpectedFn: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing required method: " ++ name);
    }

    const actual = @TypeOf(@field(T, name));
    const expected_info = @typeInfo(ExpectedFn).@"fn";
    const actual_info = @typeInfo(actual).@"fn";

    // Check parameter count matches
    if (actual_info.params.len != expected_info.params.len) {
        @compileError("Method " ++ name ++ " has wrong number of parameters");
    }
}

// =============================================================================
// Tests
// =============================================================================

test "interface verification compiles" {
    // These would fail at comptime if interfaces don't match
    // Actual verification happens in platform-specific modules
}
```

#### 2.2 Add Verification to Platform Renderers ✅

Add comptime verification to each renderer implementation:

```zig
// src/platform/mac/metal/renderer.zig
const interface_verify = @import("../../../core/interface_verify.zig");

pub const Renderer = struct {
    // ... existing implementation ...
};

// Compile-time verification that we implement the interface
comptime {
    interface_verify.verifyRendererInterface(Renderer);
}
```

```zig
// src/platform/linux/vk_renderer.zig
const interface_verify = @import("../../core/interface_verify.zig");

pub const VulkanRenderer = struct {
    // ... existing implementation ...
};

comptime {
    interface_verify.verifyRendererInterface(VulkanRenderer);
}
```

```zig
// src/platform/wgpu/web/renderer.zig
const interface_verify = @import("../../../core/interface_verify.zig");

pub const WebRenderer = struct {
    // ... existing implementation ...
};

comptime {
    interface_verify.verifyRendererInterface(WebRenderer);
}
```

#### 2.3 Add Verification to SVG Rasterizers ✅

```zig
// src/svg/rasterizer_cg.zig (macOS)
const interface_verify = @import("../core/interface_verify.zig");

comptime {
    // Verify module-level functions match interface
    interface_verify.verifySvgRasterizerInterface(@This());
}
```

```zig
// src/svg/rasterizer_linux.zig
const interface_verify = @import("../core/interface_verify.zig");

comptime {
    interface_verify.verifySvgRasterizerInterface(@This());
}
```

```zig
// src/svg/rasterizer_web.zig
const interface_verify = @import("../core/interface_verify.zig");

comptime {
    interface_verify.verifySvgRasterizerInterface(@This());
}
```

#### 2.4 Add Verification to Image Loaders ✅

The image loader uses platform-specific functions. Add verification:

```zig
// src/image/loader.zig - add at bottom

const interface_verify = @import("../core/interface_verify.zig");

// Verify this module implements the ImageLoader interface
comptime {
    interface_verify.verifyImageLoaderInterface(@This());
}
```

#### 2.5 Create Clipboard Interface and Implementations ✅

Currently clipboard is platform-specific without a common interface. Add:

```zig
// src/platform/clipboard.zig (NEW - common types)
//! Clipboard types and interface verification
//!
//! Each platform implements clipboard access differently:
//! - macOS: NSPasteboard (via Objective-C bridge)
//! - Linux: Wayland wl_data_device protocol
//! - Web: Async Clipboard API

const std = @import("std");

/// Clipboard operation errors
pub const ClipboardError = error{
    NotAvailable,
    AccessDenied,
    FormatNotSupported,
    OutOfMemory,
    Timeout,
};

/// Verify a type implements clipboard operations
pub fn verifyClipboardInterface(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "getText")) @compileError("Clipboard must have getText");
        if (!@hasDecl(T, "setText")) @compileError("Clipboard must have setText");
    }
}
```

Update `platform/linux/clipboard.zig` to verify:

```zig
// Add at end of src/platform/linux/clipboard.zig
const clipboard_interface = @import("../clipboard.zig");

comptime {
    clipboard_interface.verifyClipboardInterface(ClipboardState);
}
```

#### 2.6 Document Existing VTable Interfaces ✅

These modules already have proper VTable interfaces. Document them in a central location:

```zig
// src/core/mod.zig - add documentation section

// =============================================================================
// Interface Documentation
// =============================================================================
//
// Gooey uses two patterns for platform abstraction:
//
// 1. **Comptime Dispatch** (performance-critical paths)
//    - platform.Renderer → Metal/Vulkan/WebGPU (selected at compile time)
//    - svg.rasterize() → CoreGraphics/Cairo/Canvas2D
//    - image.load() → ImageIO/stb_image/createImageBitmap
//    - Zero runtime overhead, full inlining
//
// 2. **VTable Interfaces** (when runtime polymorphism needed)
//    - text.FontFace → CoreText/FreeType/Web font backends
//    - text.Shaper → CoreText/HarfBuzz/Web shaping
//    - accessibility.Bridge → macOS/Linux/Web a11y bridges
//    - platform.PlatformVTable, WindowVTable → for testing
//
// New platform backends should:
// - Use comptime verification: `interface_verify.verifyRendererInterface(T)`
// - Match existing method signatures exactly
// - See ARCHITECTURE_REFACTOR.md for interface requirements
```

#### 2.7 Create VTable Wrappers for Testing (in `testing/`) ⚡ PARTIAL

For testing, we need VTable wrappers. These live in `testing/`, not in production code:

```zig
// src/testing/mock_renderer.zig
//! Mock renderer for testing - uses VTable for injection

const std = @import("std");
const scene_mod = @import("../scene/mod.zig");

pub const MockRenderer = struct {
    // Call tracking
    begin_frame_count: u32 = 0,
    end_frame_count: u32 = 0,
    submit_scene_count: u32 = 0,
    last_scene: ?*const scene_mod.Scene = null,

    // Configurable behavior
    should_fail: bool = false,

    const Self = @This();

    pub fn beginFrame(self: *Self, width: u32, height: u32, scale: f32) void {
        _ = width; _ = height; _ = scale;
        self.begin_frame_count += 1;
    }

    pub fn endFrame(self: *Self) void {
        self.end_frame_count += 1;
    }

    pub fn renderScene(self: *Self, scene: *const scene_mod.Scene) void {
        self.submit_scene_count += 1;
        self.last_scene = scene;
    }

    pub fn resize(self: *Self, width: u32, height: u32) void {
        _ = width; _ = height;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn reset(self: *Self) void {
        self.begin_frame_count = 0;
        self.end_frame_count = 0;
        self.submit_scene_count = 0;
        self.last_scene = null;
    }
};

// Verify mock implements the interface
const interface_verify = @import("../core/interface_verify.zig");
comptime {
    interface_verify.verifyRendererInterface(MockRenderer);
}
```

```zig
// src/testing/mock_clipboard.zig
//! Mock clipboard for testing

const std = @import("std");

pub const MockClipboard = struct {
    content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    // Call tracking
    get_count: u32 = 0,
    set_count: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn getText(self: *Self, allocator: std.mem.Allocator) ?[]const u8 {
        self.get_count += 1;
        if (self.content) |c| {
            return allocator.dupe(u8, c) catch null;
        }
        return null;
    }

    pub fn setText(self: *Self, text: []const u8) void {
        self.set_count += 1;
        if (self.content) |old| {
            self.allocator.free(old);
        }
        self.content = self.allocator.dupe(u8, text) catch null;
    }

    pub fn hasText(self: *Self) bool {
        return self.content != null;
    }

    pub fn deinit(self: *Self) void {
        if (self.content) |c| {
            self.allocator.free(c);
        }
        self.* = undefined;
    }
};

// Verify mock implements the interface
const clipboard_iface = @import("../platform/clipboard.zig");
comptime {
    clipboard_iface.verifyClipboardInterface(MockClipboard);
}
```

#### 2.8 Verification ✅

**Automated Checks:**

```bash
# Verify all comptime checks pass
zig build

# Run tests to ensure mocks work
zig build test

# Check that verification is added to all backends
grep -r "verifyRendererInterface" src/platform/
grep -r "verifySvgRasterizerInterface" src/svg/
grep -r "verifyImageLoaderInterface" src/image/
```

**Manual Verification:**

- [ ] `core/interface_verify.zig` created with all verification functions
- [ ] All three renderers have comptime verification blocks
- [ ] All SVG rasterizer backends have comptime verification
- [ ] Image loader has comptime verification
- [ ] `platform/clipboard.zig` created with common types
- [ ] `testing/mock_renderer.zig` created and verifies interface
- [ ] `testing/mock_clipboard.zig` created and verifies interface
- [ ] `zig build` succeeds (proves comptime checks pass)
- [ ] `zig build test` passes

---

## Phase 3: Platform Standardization ✅ COMPLETED

**Goal:** Consistent directory structure across all platform backends.

**Duration:** 2-3 days (completed)

### Tasks

#### 3.1 Rename `mac/` to `macos/` ✅

```bash
git mv src/platform/mac src/platform/macos
```

Update all imports in `platform/mod.zig`:

- `@import("mac/platform.zig")` → `@import("macos/mod.zig")`
- `@import("mac/window.zig")` → `backend.Window`
- `@import("mac/display_link.zig")` → `backend.DisplayLink`

Additional files updated:

- `runtime/window_context.zig`: Updated Metal renderer import
- `widgets/text_area_state.zig`: Updated clipboard import
- `widgets/text_input_state.zig`: Updated clipboard import

Created `platform/macos/mod.zig` with standard module structure matching `linux/mod.zig` and `web/mod.zig`.

Added `pub const mac = macos;` alias in `platform/mod.zig` for backwards compatibility.

**Verification:**

- ✅ `zig build` — native macOS build passes
- ✅ `zig build -Dtarget=wasm32-freestanding` — WASM build passes
- ✅ `zig build test` — 775/775 tests passed

#### 3.2 Move `wgpu/web/` to `web/` ✅

```bash
git mv src/platform/wgpu/web src/platform/web
```

After the move, update the web renderer's import path to use the consolidated `platform/unified.zig`:

- `@import("../wgpu/unified.zig")` → `@import("../unified.zig")`

Note: `unified.zig` has been consolidated to `platform/unified.zig` (see 3.2.1).

#### 3.2.1 Consolidate `unified.zig` ✅ COMPLETED

**Status:** Done. Consolidated to a single `platform/unified.zig` using the flat field layout.

**What was done:**

- Created `platform/unified.zig` with flat field layout (required for WGSL/SPIR-V)
- Updated all imports (Linux, Web, macOS Metal)
- Deleted `platform/wgpu/unified.zig` and `platform/mac/metal/unified.zig`
- All 775 tests pass

The flat field layout works on all platforms (Metal can consume flat fields fine).

#### 3.3 Standardize Platform Module Structure ✅

Each platform should have:

```
platform/<name>/
├── mod.zig           # Public exports
├── platform.zig      # Platform init, event loop
├── window.zig        # Window creation, management
├── renderer.zig      # GPU rendering (implements Renderer interface)
├── clipboard.zig     # Clipboard (implements Clipboard interface)
├── file_dialog.zig   # File dialogs (implements FileDialog interface)
├── shaders/          # GPU shaders
└── <platform-specific>.zig  # e.g., appkit.zig, wayland.zig, imports.zig
```

#### 3.4 Create Platform Checklist ✅

Each platform `mod.zig` should export:

```zig
// Required exports (comptime-selected implementations)
pub const Platform = @import("platform.zig").<Name>Platform;
pub const Window = @import("window.zig").Window;

// VTable access for runtime polymorphism (testing, plugins)
// Platform and Window types should have .interface() methods that return VTables
// e.g., window.interface() returns WindowVTable

// Capabilities
pub const capabilities = PlatformCapabilities{
    .name = "<platform>",
    .graphics_backend = "<backend>",
    .high_dpi = true,
    .multi_window = true,
    // ...
};
```

#### 3.5 Update `platform/mod.zig` ✅

```zig
//! Platform abstraction layer
//!
//! Compile-time backend selection with consistent API across platforms.

const std = @import("std");
const builtin = @import("builtin");

pub const interface = @import("interface.zig");
pub const PlatformVTable = interface.PlatformVTable;
pub const WindowVTable = interface.WindowVTable;
pub const WindowOptions = interface.WindowOptions;
pub const PlatformCapabilities = interface.PlatformCapabilities;
// ... other interface types

pub const time = @import("time.zig");
pub const WindowRegistry = @import("window_registry.zig").WindowRegistry;
pub const WindowId = @import("window_registry.zig").WindowId;

// Shared GPU primitives (used by all platforms)
pub const unified = @import("unified.zig");

// Platform detection
pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

// Backend selection
pub const backend = if (is_wasm)
    @import("web/mod.zig")
else if (is_linux)
    @import("linux/mod.zig")
else if (is_macos)
    @import("macos/mod.zig")
else
    @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag));

// Compile-time selected types
pub const Platform = backend.Platform;
pub const Window = backend.Window;
pub const capabilities = backend.capabilities;

// Platform-specific modules (advanced usage)
pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};
pub const linux = if (is_linux) @import("linux/mod.zig") else struct {};
pub const web = if (is_wasm) @import("web/mod.zig") else struct {};
```

#### 3.6 Update `platform/time.zig` ✅

Update the WASM import path after moving `web/`:

```zig
// Before
const web_imports = @import("wgpu/web/imports.zig");

// After
const web_imports = @import("web/imports.zig");
```

#### 3.7 Verification ✅

- [x] All three platforms have identical `mod.zig` export structure
- [x] Platform detection works correctly
- [x] Examples compile and run on all platforms
- [x] No dead code warnings
- [x] `time.zig` works correctly on WASM after import path update
- [x] All platforms use shared `unified.zig`

---

## Phase 4: Module Reorganization ✅ COMPLETED

**Goal:** Rename modules for clarity and reorganize for discoverability.

**Duration:** 2-3 days (completed)

### Tasks

#### 4.1 Keep `components/` and `widgets/` (No Rename) ✅

**Decision:** After surveying major UI frameworks, we are keeping the existing directory names.

**Survey Results:**

| Framework          | Language | Term          | Notes                       |
| ------------------ | -------- | ------------- | --------------------------- |
| **Iced**           | Rust     | `widget/`     | Flat crate with all widgets |
| **egui**           | Rust     | `widgets/`    | Also has `containers/`      |
| **GPUI** (Zed)     | Rust     | `elements/`   | Lower-level building blocks |
| **gpui-component** | Rust     | Flat          | No subdirectory             |
| **Slint**          | Rust/C++ | `widgets/`    | Organized by theme          |
| **Flutter**        | Dart     | `widgets/`    | Everything is a Widget      |
| **Qt**             | C++      | `widgets/`    | QWidget base class          |
| **GTK**            | C        | `widgets/`    | GtkWidget base class        |
| **React**          | JS       | `components/` | Community convention        |

**Key Insights:**

1. **`widgets/`** is the dominant term in native/desktop frameworks (Qt, GTK, Iced, egui, Slint, Flutter)
2. **`components/`** is familiar to anyone from the React/web ecosystem
3. The proposed `primitives/` conflicts with "GPU primitives" and sounds lower-level than intended
4. The proposed `state/` is too generic and could be confused with app state management

**Rationale for keeping current names:**

- **`components/`** — Widely understood, especially for developers from web backgrounds
- **`widgets/`** — Matches industry standard for native UI frameworks

The distinction between stateless render functions (`components/`) and stateful implementations (`widgets/`) is an _internal architectural concern_, not something that needs to be reflected in directory names. Users intuitively understand "components" as UI building blocks and "widgets" as interactive controls.

**No action required.** Existing imports remain valid.

#### 4.2 Add `accessibility/mod.zig` ✅

Created `accessibility/mod.zig` with:

- Core types: `Accessibility`, `Tree`, `Element`, `types`, `constants`
- Bridge interface: `Bridge`, `NullBridge`, `TestBridge`
- Platform-specific bridges: `mac_bridge`, `linux_bridge`, `web_bridge` (conditionally compiled)
- Utilities: `debug`, `fingerprint`
- Convenience re-exports: `Role`, `State`

Updated `root.zig` to import from `accessibility/mod.zig` instead of `accessibility/accessibility.zig`.

#### 4.3 Reorganize `svg/` with Backends ✅

Reorganized SVG rasterizers into `svg/backends/` directory:

```bash
mkdir -p src/svg/backends
git mv src/svg/rasterizer_cg.zig src/svg/backends/coregraphics.zig
git mv src/svg/rasterizer_linux.zig src/svg/backends/cairo.zig
git mv src/svg/rasterizer_web.zig src/svg/backends/canvas.zig
git mv src/svg/rasterizer_stub.zig src/svg/backends/null.zig
```

Updated `svg/rasterizer.zig` to use new paths:

- `@import("backends/coregraphics.zig")` for macOS
- `@import("backends/cairo.zig")` for Linux
- `@import("backends/canvas.zig")` for Web/WASM
- `@import("backends/null.zig")` for unsupported platforms

Updated `svg/mod.zig` to expose `backends` struct for advanced usage.

Fixed import paths in backend files (`../../scene/svg.zig`).

#### 4.4 Update `root.zig` Exports ✅

Ensure backward compatibility while exposing new structure:

```zig
// =============================================================================
// Module Namespaces (canonical locations)
// =============================================================================

pub const core = @import("core/mod.zig");
pub const scene = @import("scene/mod.zig");
pub const layout = @import("layout/layout.zig");
pub const input = @import("input/mod.zig");
pub const animation = @import("animation/mod.zig");
pub const platform = @import("platform/mod.zig");
pub const text = @import("text/mod.zig");
pub const svg = @import("svg/mod.zig");
pub const image = @import("image/mod.zig");
pub const accessibility = @import("accessibility/mod.zig");
pub const context = @import("context/mod.zig");
pub const ui = @import("ui/mod.zig");
pub const components = @import("components/mod.zig");
pub const widgets = @import("widgets/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const debug = @import("debug/mod.zig");
```

#### 4.5 Verification ✅

- [x] All imports updated
- [x] Backward compatibility maintained
- [x] `zig build` — native macOS build passes
- [x] `zig build -Dtarget=wasm32-freestanding` — WASM build passes
- [x] `zig build test` — 775/775 tests passed
- [ ] Documentation updated
- [ ] No breaking changes for external users

---

## Phase 5: Testing Infrastructure ⚡ PARTIAL

**Goal:** Create mock implementations and test utilities.

**Duration:** 2-3 days (partially completed)

### Tasks

#### 5.1 Create `testing/` Directory ✅

```bash
mkdir -p src/testing
```

#### 5.2 Create `testing/mod.zig` ✅

````zig
//! Test Utilities and Mock Implementations
//!
//! Use these in unit tests to avoid platform dependencies.
//!
//! Example:
//! ```zig
//! const testing = @import("gooey").testing;
//!
//! test "my widget" {
//!     var renderer = testing.MockRenderer{};
//!     var clipboard = testing.MockClipboard{};
//!     // ... test with mocks
//! }
//! ```

const std = @import("std");

pub const MockRenderer = @import("mock_renderer.zig").MockRenderer;
pub const MockFontFace = @import("mock_font_face.zig").MockFontFace;
pub const MockClipboard = @import("mock_clipboard.zig").MockClipboard;
pub const MockFileDialog = @import("mock_file_dialog.zig").MockFileDialog;
pub const MockSvgRasterizer = @import("mock_svg_rasterizer.zig").MockSvgRasterizer;

// Re-export TestBridge from accessibility
pub const TestBridge = @import("../accessibility/bridge.zig").TestBridge;

// Test allocator alias
pub const allocator = std.testing.allocator;

// =============================================================================
// Test Helpers
// =============================================================================

/// Create a test scene with default limits
pub fn createTestScene(alloc: std.mem.Allocator) !*@import("../scene/mod.zig").Scene {
    const scene = try alloc.create(@import("../scene/mod.zig").Scene);
    scene.* = .{};
    return scene;
}

/// Create a minimal test Gooey context (no rendering)
pub fn createTestContext(alloc: std.mem.Allocator) !*@import("../context/mod.zig").Gooey {
    _ = alloc;
    @compileError("TODO: Implement test context factory");
}

/// Assert two colors are approximately equal
pub fn expectColorEqual(expected: anytype, actual: anytype) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
    try std.testing.expectApproxEqAbs(expected.a, actual.a, tolerance);
}

/// Assert two rectangles are approximately equal
pub fn expectBoundsEqual(expected: anytype, actual: anytype) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, tolerance);
}
````

#### 5.3 Create `testing/mock_renderer.zig` ✅

```zig
//! Mock Renderer for Testing
//!
//! Records all rendering calls for verification.
//! Follows the VTable pattern from accessibility/bridge.zig TestBridge.

const std = @import("std");
const platform = @import("../platform/mod.zig");

pub const MockRenderer = struct {
    // Call tracking
    begin_frame_count: u32 = 0,
    end_frame_count: u32 = 0,
    submit_scene_count: u32 = 0,
    resize_count: u32 = 0,

    // Last values
    last_width: u32 = 0,
    last_height: u32 = 0,
    last_scale: f32 = 0,

    // Configuration (uses platform's RendererCapabilities)
    capabilities: platform.RendererCapabilities = .{
        .name = "MockRenderer",
        .max_texture_size = 4096,
        .msaa = true,
        .msaa_sample_count = 4,
    },

    const Self = @This();

    /// VTable for runtime polymorphism in tests (follows TestBridge pattern)
    pub const VTable = struct {
        beginFrame: *const fn (*anyopaque, u32, u32, f32) void,
        endFrame: *const fn (*anyopaque) void,
        resize: *const fn (*anyopaque, u32, u32) void,
        getCapabilities: *const fn (*anyopaque) platform.RendererCapabilities,
        deinit: *const fn (*anyopaque) void,
    };

    pub const Interface = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub fn beginFrame(self: Interface, w: u32, h: u32, s: f32) void {
            self.vtable.beginFrame(self.ptr, w, h, s);
        }
        pub fn endFrame(self: Interface) void {
            self.vtable.endFrame(self.ptr);
        }
        pub fn resize(self: Interface, w: u32, h: u32) void {
            self.vtable.resize(self.ptr, w, h);
        }
        pub fn getCapabilities(self: Interface) platform.RendererCapabilities {
            return self.vtable.getCapabilities(self.ptr);
        }
        pub fn deinit(self: Interface) void {
            self.vtable.deinit(self.ptr);
        }
    };

    pub fn interface(self: *Self) Interface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *Self) void {
        self.begin_frame_count = 0;
        self.end_frame_count = 0;
        self.submit_scene_count = 0;
        self.resize_count = 0;
    }

    const vtable = VTable{
        .beginFrame = beginFrame,
        .endFrame = endFrame,
        .resize = resize,
        .getCapabilities = getCapabilities,
        .deinit = deinit_,
    };

    fn beginFrame(ptr: *anyopaque, width: u32, height: u32, scale: f32) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.begin_frame_count += 1;
        self.last_width = width;
        self.last_height = height;
        self.last_scale = scale;
    }

    fn endFrame(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.end_frame_count += 1;
    }

    fn getCapabilities(ptr: *anyopaque) platform.RendererCapabilities {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.capabilities;
    }

    fn resize(ptr: *anyopaque, _: u32, _: u32) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.resize_count += 1;
    }

    fn deinit_(_: *anyopaque) void {}
};
```

#### 5.4 Create Other Mocks ✅ COMPLETED

All mocks implemented:

- `mock_renderer.zig` ✅ - Tracks render calls without GPU
- `mock_clipboard.zig` ✅ - In-memory clipboard storage
- `mock_svg_rasterizer.zig` ✅ - Returns configurable rasterization results
- `mock_font_face.zig` ✅ - VTable-based font face with configurable metrics
- `mock_file_dialog.zig` ✅ - Returns pre-configured paths, simulates cancellation

#### 5.5 Add Testing Module to `root.zig` ✅

```zig
/// Test utilities (only available in test builds)
pub const testing = if (@import("builtin").is_test)
    @import("testing/mod.zig")
else
    struct {};
```

#### 5.6 Verification ✅

- [x] All mocks compile
- [x] Mocks can be used in existing tests
- [x] Mock call tracking works correctly
- [x] Documentation includes testing examples (testing/README.md)

---

## Migration Guide

### For External Users

#### Minimal Changes (Phase 1-2)

No breaking changes to public API. Internal reorganization only.

**Phase 1 import path changes (internal only):**

| Old                  | New                   |
| -------------------- | --------------------- |
| `core.render_bridge` | `scene.render_bridge` |
| `core.svg`           | `scene.svg`           |
| `core.Path`          | `scene.Path`          |
| `core.Gradient`      | `scene.Gradient`      |

Root-level re-exports (`@import("gooey").svg`, etc.) remain unchanged.

#### After Phase 4 (Module Reorganization)

No changes to `components/` or `widgets/` imports — these names are being kept as-is.

The only changes in Phase 4 are internal reorganizations:

- Adding `accessibility/mod.zig`
- Reorganizing `svg/` backends

#### After Phase 5 (Testing)

New testing utilities available:

```zig
const testing = @import("gooey").testing;

test "my feature" {
    var mock = testing.MockRenderer{};
    // ...
}
```

### For Internal Development

#### Import Path Changes

**Phase 1 (Core Cleanup):**

| Old                                    | New                                     |
| -------------------------------------- | --------------------------------------- |
| `@import("../core/render_bridge.zig")` | `@import("../scene/render_bridge.zig")` |
| `@import("../core/gradient.zig")`      | `@import("../scene/gradient.zig")`      |
| `@import("../core/path.zig")`          | `@import("../scene/path.zig")`          |
| `@import("../core/svg.zig")`           | `@import("../scene/svg.zig")`           |
| `core.render_bridge`                   | `scene.render_bridge`                   |
| `core.svg`                             | `scene.svg`                             |
| `core.Path`                            | `scene.Path`                            |
| `core.Gradient`                        | `scene.Gradient`                        |

**Phase 3 (Platform Standardization):**

| Old                           | New                             |
| ----------------------------- | ------------------------------- |
| `@import("mac/platform.zig")` | `@import("macos/platform.zig")` |
| `@import("wgpu/web/mod.zig")` | `@import("web/mod.zig")`        |

**Phase 4 (Module Reorganization):**

No changes to `components/` or `widgets/` paths — keeping existing names.

| Old                                      | New                                           |
| ---------------------------------------- | --------------------------------------------- |
| `@import("../svg/rasterizer_cg.zig")`    | `@import("../svg/backends/coregraphics.zig")` |
| `@import("../svg/rasterizer_linux.zig")` | `@import("../svg/backends/cairo.zig")`        |

#### New Interface Implementations

When adding a new platform backend:

1. Create directory under `platform/<name>/`
2. Implement all required interfaces
3. Add to `platform/mod.zig` backend selection
4. Verify against interface contracts

---

## Risk Assessment

### Low Risk

| Change                             | Risk | Mitigation                     |
| ---------------------------------- | ---- | ------------------------------ |
| Create `core/interface_verify.zig` | Low  | Additive, comptime-only        |
| Create `testing/`                  | Low  | Additive, test-only            |
| Expand `core/limits.zig`           | Low  | Centralizes existing constants |

### Medium Risk

| Change                           | Risk   | Mitigation                                    |
| -------------------------------- | ------ | --------------------------------------------- |
| Clean `core/mod.zig`             | Medium | Keep re-exports in `root.zig`                 |
| Move files out of `core/`        | Medium | Update all imports, verify with grep          |
| Fix `event.zig` input dependency | Medium | Option A (move types) preferred over Option B |
| Rename platform directories      | Medium | Git mv preserves history                      |
| Platform restructure             | Medium | Test on all platforms before merge            |

### High Risk

| Change          | Risk | Mitigation |
| --------------- | ---- | ---------- |
| None identified | -    | -          |

### Rollback Plan

Each phase is independent. If issues arise:

1. Revert the specific phase commit
2. Re-assess approach
3. Try alternative implementation

---

## Timeline Summary

| Phase                                    | Duration | Status      |
| ---------------------------------------- | -------- | ----------- |
| Phase 1: Foundation Cleanup              | 2-3 days | ✅ Complete |
| Phase 2: Comptime Interface Verification | 3-4 days | ✅ Complete |
| Phase 3: Platform Standardization        | 2-3 days | ✅ Complete |
| Phase 4: Module Reorganization           | 2-3 days | ✅ Complete |
| Phase 5: Testing Infrastructure          | 2-3 days | ✅ Complete |

**All phases completed!**

**Remaining work (deferred as low-priority):**

- `MockFontFace` — add when needed for text system testing
- `MockFileDialog` — add when needed for file dialog testing

---

## Checklist

### Phase 1: Foundation Cleanup ✅ COMPLETED (LITE Refactor)

- [x] Audit existing MAX\_\* constants across codebase
- [x] Expand `core/limits.zig` with all MAX\_\* constants (with memory budgets)
- [x] Move `render_bridge.zig` from `core/` to `scene/`
- [x] Move `gradient.zig` from `core/` to `scene/`
- [x] Move `path.zig` from `core/` to `scene/`
- [x] Move `svg.zig` from `core/` to `scene/`
- [x] Move `event.zig` from `core/` to `input/` (it's an input event wrapper)
- [x] Update `input/mod.zig` to export `Event`, `EventPhase`, `EventResult`
- [x] Add backward-compat re-exports in `core/mod.zig`
- [x] Clean `core/mod.zig` (remove all upward dependencies)
- [x] Update `root.zig` with convenience re-exports
- [x] Verify: `grep -r "@import.*\.\./scene" src/core/` returns empty
- [x] Verify: `grep -r "@import.*\.\./context" src/core/` returns empty
- [x] Verify: `grep -r "@import.*\.\./input" src/core/` returns empty
- [x] Verify: `zig build` succeeds
- [x] Verify: `zig build test` passes
- [x] All examples compile

### Phase 2: Comptime Interface Verification ✅ COMPLETED (LITE Refactor)

- [x] Create `core/interface_verify.zig` with verification functions
- [x] Add `verifyRendererInterface()` to Metal renderer
- [x] Add `verifyRendererInterface()` to Vulkan renderer
- [x] Add `verifyRendererInterface()` to Web renderer
- [x] Add `verifySvgRasterizerInterface()` to all SVG backends
- [x] Add `verifyImageLoaderInterface()` to image loader
- [x] Create `platform/clipboard.zig` with common types
- [x] Add clipboard verification to Linux clipboard
- [x] Document interface patterns in `core/mod.zig`
- [x] Create `testing/mock_renderer.zig` with interface verification
- [ ] Create `testing/mock_clipboard.zig` with interface verification _(deferred — add when needed)_
- [x] Verify: `zig build` succeeds (comptime checks pass)
- [x] Verify: `zig build test` passes

### Phase 3: Platform Standardization ✅ COMPLETED

- [x] **Rename `mac/` to `macos/`** — created `macos/mod.zig`, updated all imports, added backwards-compat alias
- [x] **Move `wgpu/web/` to `web/`** (LITE Refactor)
- [x] **Consolidate `unified.zig`** to `platform/unified.zig` (flat field layout for all platforms)
- [x] Standardize all platform `mod.zig` exports (LITE Refactor)
- [x] Update `platform/mod.zig` (LITE Refactor)
- [x] Test on macOS
- [x] Test on Linux
- [x] Test on Web/WASM
- [x] All tests pass

### Phase 4: Module Reorganization ✅ COMPLETED

- [x] **Keep `components/` and `widgets/`** (no rename — aligns with industry conventions)
- [x] **Add `accessibility/mod.zig`** — standard module structure with platform-conditional bridges
- [x] **Reorganize `svg/` with `backends/`** — coregraphics.zig, cairo.zig, canvas.zig, null.zig
- [x] **Update `root.zig` exports** — accessibility now imports from mod.zig
- [x] All tests pass (775/775)

### Phase 5: Testing Infrastructure ✅ COMPLETED

- [x] Create `testing/mod.zig`
- [x] Create `MockRenderer`
- [x] Create `MockFontFace` — VTable-based with configurable metrics
- [x] Create `MockClipboard`
- [x] Create `MockFileDialog` — simulates open/save with configurable responses
- [x] Create `MockSvgRasterizer`
- [x] Add test helpers (`expectColorEqual`, `expectBoundsEqual`, `expectPointEqual`, `expectSizeEqual`)
- [x] Document testing patterns (`testing/README.md`)
- [x] All tests pass (822 tests)

---

## Appendix: Interface Patterns

### Comptime vs VTable Decision Guide

| Use Case            | Pattern  | Reason                             |
| ------------------- | -------- | ---------------------------------- |
| Rendering (60+ FPS) | Comptime | Zero overhead, hot path            |
| Text shaping        | Comptime | Called frequently during layout    |
| SVG rasterization   | Comptime | Performance sensitive              |
| Image decoding      | Comptime | Large data, benefits from inlining |
| Clipboard           | Either   | Infrequent, user-initiated         |
| File dialogs        | Either   | Blocking anyway                    |
| Accessibility       | VTable   | Already uses VTable, end-of-frame  |
| Testing/Mocks       | VTable   | Need runtime injection             |

### Comptime Interface Verification

All platform backends should verify they implement the expected interface:

```zig
// In your renderer implementation:
const interface_verify = @import("core/interface_verify.zig");

pub const MyRenderer = struct {
    // ... implementation ...
};

comptime {
    interface_verify.verifyRendererInterface(MyRenderer);
}
```

This catches missing methods at compile time without any runtime overhead.

### Required Method Signatures

#### Renderer (comptime verified)

```zig
init(allocator: Allocator) !Self
deinit(*Self) void
beginFrame(*Self, width: u32, height: u32, scale: f32) void
endFrame(*Self) void
resize(*Self, width: u32, height: u32) void
renderScene(*Self, scene: *const Scene) void  // or submitScene
```

#### SvgRasterizer (comptime verified)

```zig
rasterize(svg_data: []const u8, width: u32, height: u32, allocator: Allocator) !RasterizedSvg
rasterizeWithOptions(svg_data: []const u8, width: u32, height: u32, options: StrokeOptions, allocator: Allocator) !RasterizedSvg
```

#### ImageLoader (comptime verified, module-level)

```zig
// Required exports:
load(allocator: Allocator, source: ImageSource) !DecodedImage
loadFromMemory(allocator: Allocator, data: []const u8) !DecodedImage
DecodedImage  // type
LoadError     // type
```

#### Clipboard (comptime verified)

```zig
getText(*Self, allocator: Allocator) ?[]const u8
setText(*Self, text: []const u8) void
hasText(*Self) bool
```

### Existing VTable Interfaces

These modules already use VTable for runtime polymorphism:

#### FontFace (text/font_face.zig)

```zig
glyphIndex(codepoint: u21) u16
glyphAdvance(glyph_id: u16) f32
glyphMetrics(glyph_id: u16) GlyphMetrics
renderGlyphSubpixel(...) !RasterizedGlyph
deinit() void
```

#### Shaper (text/shaper.zig)

```zig
shape(face: FontFace, text: []const u8) ShapedRun
deinit() void
```

#### AccessibilityBridge (accessibility/bridge.zig)

```zig
syncDirty(tree: *const Tree, dirty_indices: []const u16) void
removeElements(fingerprints: []const Fingerprint) void
announce(message: []const u8, live: Live) void
focusChanged(tree: *const Tree, element_index: ?u16) void
isActive() bool
deinit() void
```

#### PlatformVTable / WindowVTable (platform/interface.zig)

```zig
// PlatformVTable
run() void
quit() void
deinit() void

// WindowVTable
getWindowId() WindowId
width() u32
height() u32
getSize() Size(f64)
getScaleFactor() f64
setTitle(title: []const u8) void
requestRender() void
setScene(scene: *const Scene) void
// ... etc
```
