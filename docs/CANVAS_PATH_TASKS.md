# Canvas Path Implementation — Task Breakdown

This document breaks down the [CANVAS_PATH_IMPLEMENTATION.md](./CANVAS_PATH_IMPLEMENTATION.md) into actionable, sprint-sized tasks.

**Implementation file:** `src/ui/canvas.zig`

---

## Current Status

| Phase | Status      | Notes                                          |
| ----- | ----------- | ---------------------------------------------- |
| 0     | ✅ Complete | GPU tessellation, pipelines, scene integration |
| 1     | ✅ Complete | Path Builder API with fluent interface         |
| 2     | ✅ Complete | Canvas element with DrawContext API            |
| 3     | ✅ Complete | Gradients (linear/radial) with up to 16 stops  |
| 4     | ✅ Complete | Stroke API with direct triangulation           |
| 5     | 🔲 Optional | SDF feathering (likely not needed with MSAA)   |

**Last Updated:** Phase 4 complete — All strokes now use direct triangulation (bypasses ear-clipper), fixing complex corner join failures. LineCap/LineJoin, toStrokeMesh() on Path, strokePath/strokeCircle/strokeLine on DrawContext all working.

---

## Overview

| Phase | Name                | Priority | Est. Effort | Dependencies       | Status      |
| ----- | ------------------- | -------- | ----------- | ------------------ | ----------- |
| 0     | GPU Tessellation    | 🔴 P0    | 1-2 weeks   | None (BLOCKER)     | ✅ Complete |
| 1     | Path Builder API    | 🔴 P0    | 3-4 days    | Phase 0            | ✅ Complete |
| 2     | Canvas Element      | 🟡 P1    | 1 week      | Phase 0, 1         | ✅ Complete |
| 3     | Gradients           | 🟡 P1    | 1 week      | Phase 2            | ✅ Complete |
| 4     | Stroke Rendering    | 🟢 P2    | 1 week      | Phase 1            | ✅ Complete |
| 5     | SDF Edge Feathering | 🟢 P3    | 3-4 days    | Phase 0 (optional) | 🔲 Optional |

---

## Phase 0: GPU Tessellation ✅ COMPLETE

**This unlocks everything. Nothing else can proceed without it.**

> **Implementation Notes:**
>
> - MeshPool changed to lazy heap allocation (~88MB would overflow stack)
> - Custom `FixedArray` used instead of `std.BoundedArray` (not in Zig 0.15)
> - signedArea formula corrected to proper shoelace formula
> - WebGPU renders paths individually (each has unique mesh)

### Task 0.1: Triangulator Core

**File:** `src/core/triangulator.zig`  
**Effort:** 2-3 days

- [x] Create `triangulator.zig` with constants:
  - `MAX_PATH_VERTICES = 4096`
  - `MAX_PATH_TRIANGLES = 4094`
  - `MAX_PATH_INDICES = 12282`
- [x] Implement `Vec2` struct with `sub()` method
- [x] Implement `signedArea()` for winding detection
- [x] Implement `isConvex()` with winding-aware test
- [x] Implement `pointInTriangle()` helper
- [x] Implement `hasPointInside()` helper
- [x] Implement `Triangulator` struct with:
  - `init()` / `reset()`
  - `triangulate()` — main entry point
  - `earClipPolygon()` — core algorithm
- [x] Add safety counter to prevent infinite loops (O(n²) limit)
- [x] Add 2+ assertions per function (per CLAUDE.md)

**Acceptance:**

```zig
// Should triangulate a square into 2 triangles
const square = [_]Vec2{ .{0,0}, .{1,0}, .{1,1}, .{0,1} };
const indices = try triangulator.triangulate(&square, .{ .start = 0, .end = 4 });
try std.testing.expectEqual(@as(usize, 6), indices.len);
```

---

### Task 0.2: PathMesh Structure

**File:** `src/scene/path_mesh.zig`  
**Effort:** 1 day

- [x] Create `PathVertex` extern struct (16 bytes):
  - `x, y: f32` — position
  - `u, v: f32` — UV for gradients
- [x] Add comptime size assertion: `@sizeOf(PathVertex) == 16`
- [x] Create `PathMesh` struct with:
  - `vertices: BoundedArray(PathVertex, MAX_MESH_VERTICES)`
  - `indices: BoundedArray(u32, MAX_MESH_INDICES)`
  - `bounds: Bounds`
- [x] Implement `fromFlattenedPath()`:
  - Calculate bounds during vertex iteration
  - Generate UV coords normalized to bounds
  - Call triangulator for each polygon

**Acceptance:**

```zig
const mesh = try PathMesh.fromFlattenedPath(points, polygons);
try std.testing.expect(mesh.indices.len > 0);
try std.testing.expect(mesh.bounds.width > 0);
```

---

### Task 0.3: MeshPool Caching

**File:** `src/scene/mesh_pool.zig`  
**Effort:** 1 day

- [x] Define constants:
  - `MAX_PERSISTENT_MESHES = 512`
  - `MAX_FRAME_MESHES = 256`
- [x] Create `MeshRef` union: `persistent: u16 | frame: u16`
- [x] Implement `MeshPool` with two tiers (lazy heap allocation):
  - **Persistent**: hash-keyed cache for icons/static shapes
  - **Frame**: scratch allocator, reset each frame
- [x] Implement methods:
  - `getOrCreatePersistent(mesh, hash)` — cache lookup + store
  - `allocateFrame(mesh)` — scratch allocation
  - `getMesh(ref)` — unified access
  - `resetFrame()` — called at frame start
  - `clearPersistent()` — theme change / memory pressure

**Acceptance:**

```zig
var pool = MeshPool.init();
const ref1 = try pool.getOrCreatePersistent(mesh, hash);
const ref2 = try pool.getOrCreatePersistent(mesh, hash);
try std.testing.expectEqual(ref1.persistent, ref2.persistent); // Cache hit
```

---

### Task 0.4: PathInstance Scene Primitive

**File:** `src/scene/path_instance.zig`  
**Effort:** 0.5 days

- [x] Create `PathInstance` extern struct (80 bytes):
  - `order: DrawOrder` — z-ordering
  - `offset_x, offset_y: f32` — position
  - `scale_x, scale_y: f32` — transform
  - `mesh_ref_type, mesh_ref_index: u32` — mesh reference
  - `vertex_offset, index_offset, index_count: u32` — buffer ranges
  - `fill_color: Hsla`
  - `clip_*: f32` — clip bounds
- [x] Add comptime size assertion: `@sizeOf(PathInstance) == 80`
- [x] Implement `init()` with assertions for NaN checks

---

### Task 0.5: Scene Integration

**File:** `src/scene/scene.zig` (modify existing)  
**Effort:** 0.5 days

- [x] Add to Scene struct:
  - `path_instances: BoundedArray(PathInstance, 4096)`
  - `mesh_pool: MeshPool`
- [x] Implement `insertPath(instance)`:
  - Assign draw order
  - Apply current clip bounds
- [x] Implement `insertPathWithMesh(mesh, base_instance)`:
  - Allocate mesh in frame pool
  - Call `insertPath()`
- [x] Implement `getPathInstances()`
- [x] Update `resetFrame()` to reset path_instances and mesh_pool

---

### Task 0.6: Metal Path Pipeline

**Files:** `src/platform/mac/metal/` + shader  
**Effort:** 2 days

- [x] Create `path.metal` shader:
  - Vertex shader: transform position, pass UV/color
  - Fragment shader: output fill color (solid for now)
- [x] Create path render pipeline in renderer:
  - Use existing `sample_count` for MSAA
  - Share MSAA texture with quad rendering
  - Index buffer support
- [x] Upload path vertices/indices to GPU buffers
- [x] Render path instances in draw loop
- [x] Verify MSAA resolve includes paths

**Acceptance:** Render a simple triangle/square path visible on screen.

---

### Task 0.7: WebGPU Path Pipeline

**Files:** `src/platform/wgpu/` + shader  
**Effort:** 2 days

- [x] Create `path.wgsl` shader (mirror Metal)
- [x] Create WebGPU path render pipeline
- [x] Verify MSAA integration via existing `sample_count`
- [ ] Test in browser (manual verification needed)

---

### Task 0.8: Triangulator Tests

**File:** `src/core/triangulator_test.zig`  
**Effort:** 0.5 days

- [x] Test: Square → 2 triangles
- [x] Test: Convex polygon → (n-2) triangles
- [x] Test: Concave L-shape polygon
- [x] Test: CW vs CCW winding produces same result
- [x] Test: Degenerate cases (< 3 points) return error
- [ ] Test: Collinear points handling (edge case - may need future work)
- [ ] Test: MAX_PATH_VERTICES boundary (edge case - may need future work)

---

## Phase 1: Path Builder API ✅ COMPLETE

**Completed:** Path builder with fluent API, curve flattening, mesh conversion, and hash-based caching.

### Task 1.1: Path Builder

**File:** `src/core/path.zig`  
**Effort:** 2 days

- [x] Create `Path` struct with builder pattern:
  - `moveTo(x, y)` — start new subpath
  - `lineTo(x, y)` — straight line
  - `quadTo(cx, cy, x, y)` — quadratic Bézier
  - `cubicTo(c1x, c1y, c2x, c2y, x, y)` — cubic Bézier
  - `arcTo(...)` — arc segment
  - `closePath()` — close current subpath
- [x] Store commands in bounded array (FixedArray with MAX_PATH_COMMANDS=2048)
- [x] Implement `hash()` for cache keys (FNV-1a hash)
- [x] Convenience shape methods: `rect()`, `roundedRect()`, `circle()`, `ellipse()`

---

### Task 1.2: Path → Mesh Conversion ✅

**File:** `src/core/path.zig` (continuation)  
**Effort:** 1 day

- [x] Implement `toMesh(tolerance)`:
  - Flatten curves via recursive subdivision (quadratic, cubic, arc)
  - Call `PathMesh.fromFlattenedPath()`
  - Return error if too complex or empty
- [x] Implement `toCachedMesh(pool, tolerance)`:
  - Compute hash via FNV-1a
  - Check pool for existing mesh
  - Create and cache if miss

---

### Task 1.3: Path Builder Tests ✅

**File:** `src/core/path_test.zig`  
**Effort:** 0.5 days

- [x] Test: Rectangle builder → valid mesh
- [x] Test: Circle approximation → valid mesh
- [x] Test: Star shape with convex/concave vertices
- [x] Test: hash() produces consistent values
- [x] Test: toCachedMesh() returns same ref for same path
- [x] Additional tests: pentagon, L-shape, arrow, curves, edge cases

---

## Phase 2: Canvas Element ✅ COMPLETE

**Completed:** Canvas component with DrawContext API for custom vector graphics.

> **Implementation Notes:**
>
> - Uses deferred rendering pattern (like pending_inputs) instead of layout command
> - Canvas reserves layout space via `box()`, paint callback runs after layout
> - DrawContext provides immediate-mode API (fillRect, fillPath, fillCircle, etc.)
> - Cached paths avoid re-tessellation for repeated draws
> - Static paths use persistent cache (survives across frames)
> - Metal batch rendering fix: multiple paths now upload to shared GPU buffers with proper offsets (was overwriting buffer at offset 0 for each path)

### Task 2.1: DrawContext ✅

**File:** `src/ui/canvas.zig`  
**Effort:** 2 days

- [x] Create `DrawContext` struct holding scene reference
- [x] Immediate-mode API:
  - `fillRect(x, y, w, h, color)`
  - `fillRoundedRect(x, y, w, h, radius, color)`
  - `fillPath(path, color)`
  - `fillCircle(cx, cy, r, color)`
  - `fillEllipse(cx, cy, rx, ry, color)`
  - `strokeRect(x, y, w, h, color, stroke_width)`
  - `line(x1, y1, x2, y2, line_width, color)`
  - `fillTriangle(x1, y1, x2, y2, x3, y3, color)`
- [x] Cached-mode API:
  - `cachePath(path)` — returns CachedPath
  - `fillCached(cached, color)`
  - `fillCachedAt(cached, x, y, color)`
- [x] Static path API:
  - `fillStaticPath(path, color)` — uses persistent cache
  - `fillStaticPathAt(path, x, y, color)`

---

### Task 2.2: Canvas Component ✅

**File:** `src/ui/canvas.zig` (continuation)  
**Effort:** 1.5 days

- [x] Create `Canvas` UI element with callback: `fn(*DrawContext) void`
- [x] Integrate with layout system (width, height via box)
- [x] Handle coordinate transform (origin at canvas top-left)
- [x] Support clip bounds from parent (via scene clipping)
- [x] Add `PendingCanvas` struct for deferred rendering
- [x] Update Builder with `pending_canvas` array and `registerPendingCanvas()`
- [x] Update frame.zig to render canvas elements after layout

---

### Task 2.3: Canvas Example ✅

**File:** `examples/canvas_demo.zig`  
**Effort:** 0.5 days

- [x] Demo: Custom shape rendering (star, circles, rectangles, triangles)
- [x] Demo: Simple bar chart with cached paths
- [x] Demo: Interactive shapes with Bézier curves

---

## Phase 3: Gradients ✅ COMPLETE

**Completed:** Linear and radial gradient support with up to 16 color stops.

> **Implementation Notes:**
>
> - GradientUniforms (352 bytes) stores stop data in parallel arrays for GPU efficiency
> - PathInstance expanded to 112 bytes (was 80) with gradient type and params
> - Shaders sample gradients in UV space with hue interpolation (shortest path around color wheel)
> - Scene stores parallel array of gradient data alongside path instances

### Task 3.1: Gradient Types ✅

**File:** `src/core/gradient.zig`  
**Effort:** 1 day

- [x] Create `GradientStop` struct: `offset: f32, color: Hsla`
- [x] Create `LinearGradient` struct:
  - Start/end points
  - Up to 16 stops (hard limit)
  - Fluent `addStop()` API
  - Convenience: `horizontal()`, `vertical()`, `diagonal()`, `twoStop()`
- [x] Create `RadialGradient` struct:
  - Center, radius, inner_radius
  - Up to 16 stops
  - Support for ring gradients
- [x] Create `Gradient` tagged union for generic gradient handling

---

### Task 3.2: Gradient Uniforms ✅

**File:** `src/scene/gradient_uniforms.zig`  
**Effort:** 0.5 days

- [x] Create GPU-compatible `GradientUniforms` struct (352 bytes)
- [x] Pack stops into fixed-size arrays (offsets, h, s, l, a)
- [x] Handle linear/radial type flag
- [x] `fromLinear()`, `fromRadial()`, `fromGradient()` constructors

---

### Task 3.3: Gradient Shaders ✅

**Files:** `path_pipeline.zig` (Metal), `path.wgsl` (WebGPU)  
**Effort:** 2 days

- [x] Metal: Add `sample_gradient()` function in fragment shader
- [x] WebGPU: Add `sample_gradient()` function in fragment shader
- [x] Use UV coords from PathVertex for gradient lookup
- [x] Support both linear and radial interpolation
- [x] Hue wrapping for smooth color wheel transitions
- [x] Gradient uniform buffer binding (buffer 0 for fragment shader)

---

### Task 3.4: DrawContext Gradient API ✅

**File:** `src/ui/canvas.zig`  
**Effort:** 0.5 days

- [x] Add `fillPathLinearGradient(path, gradient)`
- [x] Add `fillPathRadialGradient(path, gradient)`
- [x] Add `fillRectLinearGradient(x, y, w, h, gradient)`
- [x] Add `fillRectRadialGradient(x, y, w, h, gradient)`
- [x] Add `fillCircleRadialGradient(cx, cy, r, gradient)`
- [x] Coordinate normalization from path space to UV space

---

## Phase 4: Stroke Rendering ✅ COMPLETE

**Status:** All stroke functionality complete. Direct triangulation is now used for all strokes (both open and closed paths), bypassing the ear-clipper entirely. This fixes all previous issues with complex corner joins.

### Task 4.1: Stroke Expansion ✅

**File:** `src/core/stroke.zig`  
**Effort:** 3 days

- [x] Implement `expandStroke()`:
  - Convert path to thick polygon
  - Handle line width
- [x] Implement `LineCap` enum: `butt, round, square`
- [x] Implement `LineJoin` enum: `miter, round, bevel`
- [x] Handle miter limit for sharp angles
- [x] Return expanded path as fill-able polygon
- [x] Special case for single-segment strokes (optimized)

**Fix Applied:** All strokes now route through `expandStrokeToTriangles()` which performs direct quad-based triangulation, avoiding ear-clipper failures on concave stroke polygons.

---

### Task 4.2: Path Stroke Method ✅

**File:** `src/core/path.zig`  
**Effort:** 1 day

- [x] Add `toStrokeMesh(width, cap, join, tolerance)`
- [x] Add `toStrokeMeshSimple(width, tolerance)` convenience
- [x] Add `flattenForStroke()` (keeps 2-point subpaths)
- [x] Use stroke expansion → triangulation pipeline

---

### Task 4.3: DrawContext Stroke API ✅

**File:** `src/ui/canvas.zig`  
**Effort:** 0.5 days

- [x] Add `strokePath(path, width, color)`
- [x] Add `strokePathStyled(path, width, color, cap, join)`
- [x] Add `strokeCircle(cx, cy, r, width, color)`
- [x] Add `strokeEllipse(cx, cy, rx, ry, width, color)`
- [x] Add `strokeLine(x1, y1, x2, y2, width, color)`
- [x] Add `strokeLineStyled(...)` with custom cap
- [x] Note: `strokeRect` uses existing quad border (more efficient)

---

## Phase 5: SDF Edge Feathering 🔲 OPTIONAL

**Only implement if aliasing is visible at small scales or during animation.**

**Note:** With 4x MSAA enabled by default, this is likely unnecessary for most UI use cases.

### Task 5.1: Barycentric Coordinates

**Effort:** 1 day

- [ ] Add barycentric coords to `PathVertex`
- [ ] Compute in vertex shader from triangle winding

### Task 5.2: Feathered Fragment Shader

**Effort:** 1 day

- [ ] Add `path_fragment_feathered()` variant
- [ ] Use `smoothstep()` on edge distance
- [ ] Add `PathInstance.feather_edges` flag (default: false)

### Task 5.3: Performance Validation

**Effort:** 0.5 days

- [ ] Benchmark with/without feathering
- [ ] Verify <10% fragment shader overhead

---

## Quick Start: First Milestone ✅ ACHIEVED

**Goal:** ~~Render a solid-color triangle on screen via GPU tessellation.~~ **DONE**

```
Task 0.1 (Triangulator)        ✅
    → Task 0.2 (PathMesh)      ✅
    → Task 0.3 (MeshPool)      ✅
    → Task 0.4 (PathInstance)  ✅
    → Task 0.5 (Scene Integration) ✅
    → Task 0.6 (Metal Pipeline)    ✅
    → Task 0.7 (WebGPU Pipeline)   ✅
    → Task 1.1 (Path Builder)      ✅
    → Task 1.2 (Mesh Conversion)   ✅
    → Task 1.3 (Tests)             ✅
```

**Next milestone:** Canvas Element (Phase 2)

1. ~~MeshPool caching~~ ✅ Done with lazy heap allocation
2. ~~Path Builder~~ ✅ Done with fluent API
3. Canvas component — **Next up**

---

## Next Steps

**Phase 2 Complete!** Canvas component is ready for use.

**To start Phase 3 (Gradients):**

1. Create `src/core/gradient.zig` with GradientStop, LinearGradient, RadialGradient
2. Create `src/scene/gradient_uniforms.zig` for GPU uniform data
3. Update path shaders to sample gradients from UV coordinates
4. Add `fillGradient()` methods to DrawContext

**Example usage (Canvas API):**

```zig
const gooey = @import("gooey");
const ui = gooey.ui;

fn paintCustom(ctx: *ui.DrawContext) void {
    // Background
    ctx.fillRoundedRect(0, 0, ctx.width(), ctx.height(), 8, ui.Color.hex(0x16213e));

    // Draw a star using path builder
    var star = ctx.beginPath(100, 10);
    _ = star.lineTo(120, 80)
            .lineTo(190, 80)
            .lineTo(130, 120)
            .close();
    ctx.fillPath(&star, ui.Color.gold);

    // Draw circles
    ctx.fillCircle(50, 50, 30, ui.Color.red);
    ctx.fillEllipse(150, 50, 40, 25, ui.Color.blue);

    // Draw with cached path (efficient for repeated shapes)
    var bar = ctx.beginPath(0, 0);
    _ = bar.lineTo(20, 0).lineTo(20, 100).lineTo(0, 100).close();

    if (ctx.cachePath(&bar)) |cached| {
        // Draw same shape multiple times - only 1 tessellation!
        ctx.fillCachedAt(cached, 200, 50, ui.Color.green);
        ctx.fillCachedAt(cached, 230, 70, ui.Color.cyan);
    }
}

// In your UI:
pub fn view(cx: *gooey.Cx) void {
    ui.canvas(400, 300, paintCustom).render(cx.builder());
}
```

---

## File Checklist

```
src/core/
├── triangulator.zig       [x] Phase 0 ✅
├── path.zig               [x] Phase 1,4 ✅ (toStrokeMesh added)
├── path_test.zig          [x] Phase 1,4 ✅
├── stroke.zig             [x] Phase 4 ✅
└── gradient.zig           [x] Phase 3 ✅

src/scene/
├── path_mesh.zig          [x] Phase 0 ✅
├── path_instance.zig      [x] Phase 0 ✅
├── mesh_pool.zig          [x] Phase 0 ✅
├── batch_iterator.zig     [x] Phase 0 ✅ (already had path support)
├── gradient_uniforms.zig  [x] Phase 3 ✅
└── scene.zig              [x] Phase 0,3 ✅ (modified - gradient storage)

src/ui/
├── canvas.zig             [x] Phase 2,3,4 ✅ (gradient + stroke methods)
├── builder.zig            [x] Phase 2 ✅ (modified - pending_canvas)
└── mod.zig                [x] Phase 2,3,4 ✅ (gradient + stroke exports)

src/platform/mac/metal/
├── path_pipeline.zig      [x] Phase 0,3 ✅ (gradient shader, buffer)
├── renderer.zig           [x] Phase 0 ✅ (modified)
└── scene_renderer.zig     [x] Phase 0,3 ✅ (gradient data passing)

src/platform/wgpu/
├── shaders/path.wgsl      [x] Phase 0,3 ✅ (gradient sampling)
└── web/renderer.zig       [x] Phase 0,3 ✅ (gradient buffer upload)
    web/imports.zig        [x] Phase 0,3 ✅ (gradient bind group)

src/runtime/
└── frame.zig              [x] Phase 2 ✅ (modified - renderCanvasElements)

web/
└── index.html             [x] Phase 0 ✅ (JS functions added)

examples/
└── canvas_demo.zig        [x] Phase 2,3 ✅ (gradient demos)

web/
└── index.html             [x] Phase 0,3 ✅ (gradient bind group JS)
```

`[x]` = complete, `[ ]` = pending

---

## Notes for Implementation

1. **Static Allocation**: All pools have hard limits. Fail fast if exceeded.
2. **Assertions**: Minimum 2 per function. Validate data at API boundaries.
3. **70-Line Limit**: Split large functions. Push ifs up, fors down.
4. **WASM Stack**: Large structs (>50KB) must be heap-allocated with `noinline` init.
5. **No Recursion**: Use explicit stacks for tree traversal.
