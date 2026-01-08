# Gooey Path/Canvas Implementation Plan

> **Status Update (Phase 1 Complete):** GPU tessellation foundation and Path Builder API are fully implemented. See [Implementation Notes](#implementation-notes-phase-0) for details on what was built and any deviations from the original plan.

## Current State Summary

**What You Have:**

- Complete SVG path parser (18 command types)
- Path flattening (curves → line segments)
- Platform rasterizers (CPU → bitmap → atlas texture)
- Atlas-cached icon rendering
- **SDF-based rendering** for quads, borders, rounded corners, and shadows
- **4x MSAA** on Metal, Vulkan, and WebGPU

**What's Missing:**

- ~~GPU tessellation (paths → triangles)~~ ✅ Phase 0
- ~~Runtime path builder API~~ ✅ Phase 1
- ~~Mesh caching strategy~~ ✅ Phase 0 (MeshPool)
- Canvas drawing context
- Gradients, blend modes

---

## Implementation Notes (Phase 0)

**✅ Phase 0: GPU Tessellation — COMPLETE**

All tasks in Phase 0 have been implemented and tested. Key files created:

| Component         | File                                       | Notes                                                      |
| ----------------- | ------------------------------------------ | ---------------------------------------------------------- |
| Triangulator      | `src/core/triangulator.zig`                | Ear-clipping with O(n²) safety counter                     |
| PathMesh          | `src/scene/path_mesh.zig`                  | 16-byte PathVertex, UV generation                          |
| MeshPool          | `src/scene/mesh_pool.zig`                  | **Changed:** Lazy heap allocation instead of inline arrays |
| PathInstance      | `src/scene/path_instance.zig`              | 80-byte GPU struct                                         |
| Scene Integration | `src/scene/scene.zig`                      | path_instances, mesh_pool, insertPath methods              |
| Metal Pipeline    | `src/platform/mac/metal/path_pipeline.zig` | Indexed drawing, MSAA                                      |
| WebGPU Pipeline   | `src/platform/wgpu/web/renderer.zig`       | Indexed drawing, batch rendering                           |
| Metal Shader      | Embedded in path_pipeline.zig              | Premultiplied alpha blending                               |
| WebGPU Shader     | `src/platform/wgpu/shaders/path.wgsl`      | Mirrors Metal shader                                       |

### Deviations from Original Plan

1. **MeshPool uses lazy heap allocation** — The original plan had `[512]PathMesh` inline arrays (~88MB total). This caused stack overflow. Changed to `?[]PathMesh` with lazy allocation via `allocator.alloc()` on first use. This follows CLAUDE.md guidance for structs >50KB.

2. **FixedArray instead of BoundedArray** — Zig 0.15 doesn't have `std.BoundedArray`, so a custom `FixedArray` was implemented in triangulator.zig.

3. **signedArea formula corrected** — Original used trapezoidal rule which gives opposite sign. Fixed to proper shoelace formula: `area += points[i].x * points[j].y - points[j].x * points[i].y`.

4. **WebGPU renders paths individually** — Each path instance has its own mesh, so paths are rendered one at a time rather than batched. This is fine for typical path counts (<256 per frame).

### Phase 1 Complete

**✅ Phase 1: Path Builder API — COMPLETE**

| Component      | File                     | Notes                                          |
| -------------- | ------------------------ | ---------------------------------------------- |
| Path Builder   | `src/core/path.zig`      | Fluent API, FixedArray storage, FNV-1a hashing |
| Path Tests     | `src/core/path_test.zig` | 35+ tests covering shapes, curves, caching     |
| Module Exports | `src/core/mod.zig`       | Added Path, PathCommand, PathError exports     |

**Key Features Implemented:**

- **Fluent builder pattern**: `path.moveTo().lineTo().closePath()`
- **Core commands**: `moveTo`, `lineTo`, `quadTo`, `cubicTo`, `arcTo`, `closePath`
- **Convenience shapes**: `rect()`, `roundedRect()`, `circle()`, `ellipse()`
- **Mesh conversion**: `toMesh(allocator, tolerance)` with curve flattening
- **Cache support**: `toCachedMesh(pool, allocator, tolerance)` with FNV-1a hash
- **Static allocation**: `MAX_PATH_COMMANDS=2048`, `MAX_PATH_DATA=16384`

**Deviations from Original Plan:**

1. **Self-contained curve flattening** — Instead of delegating to `svg.flattenPathView()`, Path has its own recursive subdivision for quadratic, cubic, and arc curves. This avoids coupling to the SVG module.

2. **FixedArray storage** — Uses custom `FixedArray` from triangulator.zig instead of `std.BoundedArray` (not available in Zig 0.15).

3. **Defensive lineTo** — `lineTo()` without prior `moveTo()` implicitly calls `moveTo()`, matching SVG behavior instead of asserting.

### Ready for Phase 2

The foundation supports:

- `PathMesh.fromConvexPolygon()` / `fromFlattenedPath()` for tessellation
- `scene.insertPathWithMesh()` for rendering with automatic draw order
- `MeshPool` for caching static paths (icons, UI shapes)
- `Path` builder for programmatic path construction
- Full z-order interleaving with other primitives via `BatchIterator`

---

## Existing Anti-Aliasing Infrastructure

Gooey already has robust anti-aliasing that paths will leverage:

### SDF (Signed Distance Field) Rendering

Used across all platforms for crisp, resolution-independent edges:

| Element            | SDF Function                 | Platform              |
| ------------------ | ---------------------------- | --------------------- |
| Rounded rectangles | `rounded_rect_sdf()`         | Metal, WebGPU, Vulkan |
| Borders            | Inner/outer SDF difference   | Metal, WebGPU, Vulkan |
| Shadows            | `shadow_falloff()` with blur | Metal, WebGPU, Vulkan |
| Corner radii       | Per-corner radius selection  | Metal, WebGPU, Vulkan |

**Key shader pattern (shared across platforms):**

```gooey/src/platform/mac/metal/quad.zig#L66-68
float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    float2 d = abs(pos) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}
```

Anti-aliased edges via `smoothstep(-0.5, 0.5, dist)` — 1px soft transition.

### MSAA (Multi-Sample Anti-Aliasing)

4x MSAA is enabled by default on all platforms:

| Platform | Sample Count          | Implementation                       |
| -------- | --------------------- | ------------------------------------ |
| Metal    | 4x                    | `MTLTextureType.type_2d_multisample` |
| WebGPU   | 4x (fallback to 1x)   | `createMSAATexture()` via JS         |
| Vulkan   | 4x (device-dependent) | `VK_SAMPLE_COUNT_4_BIT`              |

**MSAA resolves to final texture** — paths automatically benefit when rendered to the MSAA target.

### Path Anti-Aliasing Strategy

Paths will use a **hybrid approach**:

1. **MSAA (primary)** — handles triangle edge aliasing automatically, zero per-path cost
2. **SDF edge feathering (optional)** — for curved segments needing sub-pixel smoothing
3. **Tolerance-based flattening** — ensures curves are smooth enough that MSAA suffices

This means we do NOT need a separate SDF stroke pipeline for most UI paths — MSAA + good tessellation is sufficient.

#### When MSAA Is Enough (90% of cases)

For typical UI paths (icons, buttons, charts), 4x MSAA provides excellent quality:

```gooey/dev/null/msaa_quality.md#L1-8
Path Type              Vertices   MSAA Quality   Notes
─────────────────────────────────────────────────────────
Simple icon (16px)     20-50      Excellent      No visible aliasing
Rounded button         8-12       Excellent      Matches quad SDF quality
Chart line (100pts)    100-200    Good           Minor aliasing at sharp angles
Complex SVG logo       200-500    Good           Occasional jaggies on curves
```

#### Optional SDF Edge Feathering (Phase 5)

For paths requiring sub-pixel precision, add alpha feathering at triangle edges:

```gooey/src/platform/mac/metal/shaders/path.metal#L60-85
// Optional: SDF-style edge feathering for path triangles
// Enable via PathInstance.feather_edges flag

fragment float4 path_fragment_feathered(
    PathVertexOut in [[stage_in]],
    constant GradientUniforms& gradient [[buffer(0)]]
) {
    float4 color = path_fragment_base(in, gradient);

    // Edge feathering: use barycentric coords to detect triangle edges
    // This is computed in vertex shader from triangle winding
    float edge_dist = min(in.bary.x, min(in.bary.y, in.bary.z));

    // 0.5px feather zone at triangle edges
    float feather = smoothstep(0.0, 0.5 / in.scale, edge_dist);

    return float4(color.rgb, color.a * feather);
}
```

**When to enable edge feathering:**

| Use Case                 | MSAA Only | + Edge Feather |
| ------------------------ | --------- | -------------- |
| Icons at 1x scale        | ✅        | Overkill       |
| Icons at 0.5x scale      | ⚠️        | ✅             |
| Animated morphing paths  | ⚠️        | ✅             |
| Data viz with thin lines | ⚠️        | ✅             |
| Static UI elements       | ✅        | Overkill       |

**Performance cost:** ~5-10% fragment shader overhead when enabled. Disabled by default.

> **Key Insight:** The optional Phase 5 edge feathering is only needed for edge cases (small scale, animations). This is a genuine advantage over GPUI's approach — you're reusing infrastructure rather than building a separate path AA system.

---

## Phase 0: Foundation — GPU Triangle Tessellation ✅ COMPLETE

**Priority: 🔴 P0 | Effort: Medium | Impact: Unlocks everything**

~~This is the blocker. Without triangulated paths going to the GPU, Canvas is impossible.~~

**Status: IMPLEMENTED** — All components built and tested. See [Implementation Notes](#implementation-notes-phase-0) above.

### 0.1 Ear-Clipping Triangulator

New file `src/core/triangulator.zig`:

```gooey/src/core/triangulator.zig#L1-90
//! Polygon triangulation using ear-clipping algorithm
//!
//! Converts flattened path polygons to triangle indices for GPU rendering.
//! Uses O(n²) ear-clipping - sufficient for UI paths (typically <1000 vertices).
//!
//! Handles both CCW and CW winding via signed area detection.

const std = @import("std");
const builtin = @import("builtin");
const BoundedArray = std.BoundedArray;

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
};

pub const IndexSlice = struct {
    start: u32,
    end: u32,
};

/// Maximum vertices per path (static allocation per CLAUDE.md)
pub const MAX_PATH_VERTICES = 4096;
/// Maximum triangles = MAX_PATH_VERTICES - 2 (for simple polygon)
pub const MAX_PATH_TRIANGLES = MAX_PATH_VERTICES - 2;
/// Maximum indices = triangles * 3
pub const MAX_PATH_INDICES = MAX_PATH_TRIANGLES * 3;

pub const TriangulationError = error{
    TooManyVertices,
    DegeneratePolygon,
    EarClippingFailed,
};

pub const Triangulator = struct {
    /// Output indices buffer (static allocation)
    indices: BoundedArray(u32, MAX_PATH_INDICES),
    /// Detected winding direction (true = CCW)
    is_ccw: bool,

    pub fn init() Triangulator {
        return .{
            .indices = .{},
            .is_ccw = true,
        };
    }

    /// Reset for reuse (call between paths)
    pub fn reset(self: *Triangulator) void {
        self.indices.len = 0;
        self.is_ccw = true;
    }

    /// Triangulate a single polygon (points[start..end])
    /// Returns slice into internal indices buffer
    pub fn triangulate(
        self: *Triangulator,
        points: []const Vec2,
        polygon: IndexSlice,
    ) TriangulationError![]const u32 {
        const n = polygon.end - polygon.start;

        // Bounds checking at API boundary
        if (n > MAX_PATH_VERTICES) return error.TooManyVertices;
        if (n < 3) return error.DegeneratePolygon;

        // Assertions for internal invariants (debug only)
        std.debug.assert(polygon.end <= points.len);

        // Detect winding direction via signed area
        const poly_points = points[polygon.start..polygon.end];
        const area = signedArea(poly_points);
        self.is_ccw = area > 0;

        const start_idx = self.indices.len;
        try self.earClipPolygon(points, polygon);
        return self.indices.slice()[start_idx..];
    }
};

/// Calculate signed area of polygon (positive = CCW, negative = CW)
fn signedArea(points: []const Vec2) f32 {
    var area: f32 = 0;
    for (0..points.len) |i| {
        const j = (i + 1) % points.len;
        area += (points[j].x - points[i].x) * (points[j].y + points[i].y);
    }
    return area / 2;
}
```

### 0.2 Ear-Clipping Core Algorithm

```gooey/src/core/triangulator.zig#L95-200
fn earClipPolygon(
    self: *Triangulator,
    points: []const Vec2,
    polygon: IndexSlice,
) TriangulationError!void {
    const poly_points = points[polygon.start..polygon.end];
    const n = poly_points.len;

    // Internal assertions (already validated at API boundary)
    std.debug.assert(n >= 3);
    std.debug.assert(n <= MAX_PATH_VERTICES);
    std.debug.assert(self.indices.len + (n - 2) * 3 <= MAX_PATH_INDICES);

    // Build vertex index list (we'll remove ears as we go)
    var vertex_list: BoundedArray(u32, MAX_PATH_VERTICES) = .{};
    for (0..n) |i| {
        vertex_list.appendAssumeCapacity(@intCast(i));
    }

    var remaining = n;
    var safety_counter: u32 = 0;
    const max_iterations = n * n; // O(n²) worst case

    while (remaining > 3) {
        safety_counter += 1;
        if (safety_counter > max_iterations) {
            if (builtin.mode == .Debug) {
                std.log.warn(
                    "Ear clipping failed: {} vertices remaining after {} iterations. " ++
                    "Polygon may be self-intersecting or have collinear points.",
                    .{ remaining, safety_counter },
                );
            }
            return error.EarClippingFailed;
        }

        var found_ear = false;

        for (0..remaining) |i| {
            const prev = if (i == 0) remaining - 1 else i - 1;
            const next = if (i == remaining - 1) 0 else i + 1;

            const p0 = poly_points[vertex_list.get(prev)];
            const p1 = poly_points[vertex_list.get(i)];
            const p2 = poly_points[vertex_list.get(next)];

            // Check if this is a convex vertex (ear candidate)
            // Winding-aware: flip test for CW polygons
            if (!isConvex(p0, p1, p2, self.is_ccw)) continue;

            // Check no other vertices inside this triangle
            if (hasPointInside(poly_points, &vertex_list, prev, i, next, p0, p1, p2)) continue;

            // Found an ear! Emit triangle and remove vertex
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(prev));
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(i));
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(next));

            _ = vertex_list.orderedRemove(i);
            remaining -= 1;
            found_ear = true;
            break;
        }

        if (!found_ear) {
            if (builtin.mode == .Debug) {
                std.log.warn("No ear found with {} vertices remaining", .{remaining});
            }
            return error.EarClippingFailed;
        }
    }

    // Emit final triangle
    if (remaining == 3) {
        self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(0));
        self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(1));
        self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(2));
    }
}

/// Winding-aware convexity test
fn isConvex(p0: Vec2, p1: Vec2, p2: Vec2, is_ccw: bool) bool {
    const v1 = p1.sub(p0);
    const v2 = p2.sub(p1);
    const cross = v1.x * v2.y - v1.y * v2.x;
    return if (is_ccw) cross > 0 else cross < 0;
}

/// Check if any vertex (other than the triangle's own) lies inside the triangle
fn hasPointInside(
    poly_points: []const Vec2,
    vertex_list: *const BoundedArray(u32, MAX_PATH_VERTICES),
    prev: usize,
    curr: usize,
    next: usize,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
) bool {
    for (0..vertex_list.len) |i| {
        if (i == prev or i == curr or i == next) continue;

        const pt = poly_points[vertex_list.get(i)];
        if (pointInTriangle(pt, p0, p1, p2)) return true;
    }
    return false;
}

fn pointInTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
    const d1 = sign(p, a, b);
    const d2 = sign(p, b, c);
    const d3 = sign(p, c, a);

    const has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0);

    return !(has_neg and has_pos);
}

fn sign(p1: Vec2, p2: Vec2, p3: Vec2) f32 {
    return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
}
```

### 0.3 PathMesh — GPU-Ready Structure

New file `src/scene/path_mesh.zig`:

```gooey/src/scene/path_mesh.zig#L1-100
//! PathMesh - Triangulated path ready for GPU rendering
//!
//! Contains vertex positions and triangle indices suitable for
//! direct upload to vertex/index buffers.

const std = @import("std");
const scene = @import("scene.zig");
const triangulator = @import("../core/triangulator.zig");

/// Maximum vertices per mesh (static allocation)
pub const MAX_MESH_VERTICES = triangulator.MAX_PATH_VERTICES;
/// Maximum indices per mesh
pub const MAX_MESH_INDICES = triangulator.MAX_PATH_INDICES;

pub const PathVertex = extern struct {
    x: f32,
    y: f32,
    // UV coords for gradient/pattern fill (normalized to bounds)
    u: f32 = 0,
    v: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(PathVertex) == 16);
}

pub const PathMesh = struct {
    vertices: std.BoundedArray(PathVertex, MAX_MESH_VERTICES),
    indices: std.BoundedArray(u32, MAX_MESH_INDICES),
    bounds: scene.Bounds,

    pub fn init() PathMesh {
        return .{
            .vertices = .{},
            .indices = .{},
            .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    }

    /// Build mesh from flattened path
    /// Returns error if path is too complex or degenerate
    pub fn fromFlattenedPath(
        points: []const triangulator.Vec2,
        polygons: []const triangulator.IndexSlice,
    ) !PathMesh {
        var mesh = PathMesh.init();
        var tri = triangulator.Triangulator.init();

        // Calculate bounds and convert points to vertices
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (points) |p| {
            if (mesh.vertices.len >= MAX_MESH_VERTICES) {
                return error.TooManyVertices;
            }
            mesh.vertices.appendAssumeCapacity(.{ .x = p.x, .y = p.y });
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        mesh.bounds = .{
            .x = min_x,
            .y = min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };

        // Generate UV coordinates (normalized to bounds)
        const w = if (mesh.bounds.width > 0) mesh.bounds.width else 1;
        const h = if (mesh.bounds.height > 0) mesh.bounds.height else 1;
        for (mesh.vertices.slice()) |*vtx| {
            vtx.u = (vtx.x - min_x) / w;
            vtx.v = (vtx.y - min_y) / h;
        }

        // Triangulate each polygon
        for (polygons) |poly| {
            const tri_indices = try tri.triangulate(points, poly);
            for (tri_indices) |idx| {
                if (mesh.indices.len >= MAX_MESH_INDICES) {
                    return error.TooManyIndices;
                }
                mesh.indices.appendAssumeCapacity(idx);
            }
        }

        return mesh;
    }
};
```

### 0.4 MeshPool — Two-Tier Caching System

New file `src/scene/mesh_pool.zig`:

```gooey/src/scene/mesh_pool.zig#L1-110
//! MeshPool - Two-tier mesh caching for optimal performance
//!
//! Tier 1: Persistent meshes (icons, static shapes) - cached by hash
//! Tier 2: Per-frame scratch (dynamic paths, animations) - reset each frame
//!
//! Usage patterns:
//! - Icons/static UI: Hash the SVG path string, use getOrCreatePersistent()
//! - Charts/animations: Use allocateFrame(), it auto-clears each frame
//! - Canvas callback paths: Always frame-local (user rebuilds each frame anyway)

const std = @import("std");
const PathMesh = @import("path_mesh.zig").PathMesh;

pub const MAX_PERSISTENT_MESHES = 512;
pub const MAX_FRAME_MESHES = 256;

pub const MeshRef = union(enum) {
    persistent: u16,
    frame: u16,

    pub fn index(self: MeshRef) u16 {
        return switch (self) {
            .persistent => |i| i,
            .frame => |i| i,
        };
    }
};

pub const MeshPool = struct {
    // Tier 1: Persistent meshes (icons, static shapes)
    persistent: [MAX_PERSISTENT_MESHES]PathMesh,
    persistent_hashes: [MAX_PERSISTENT_MESHES]u64,
    persistent_count: u32,

    // Tier 2: Per-frame scratch (dynamic paths, animations)
    frame_meshes: [MAX_FRAME_MESHES]PathMesh,
    frame_count: u32,

    pub fn init() MeshPool {
        return .{
            .persistent = undefined,
            .persistent_hashes = [_]u64{0} ** MAX_PERSISTENT_MESHES,
            .persistent_count = 0,
            .frame_meshes = undefined,
            .frame_count = 0,
        };
    }

    /// Get or create persistent mesh (for static paths like icons)
    /// Hash should be computed from path data for cache lookup
    pub fn getOrCreatePersistent(
        self: *MeshPool,
        mesh: PathMesh,
        hash: u64,
    ) error{MeshPoolFull}!MeshRef {
        // Check cache first
        for (self.persistent_hashes[0..self.persistent_count], 0..) |h, i| {
            if (h == hash) return MeshRef{ .persistent = @intCast(i) };
        }

        // Cache miss - store new mesh
        if (self.persistent_count >= MAX_PERSISTENT_MESHES) {
            return error.MeshPoolFull;
        }

        const idx = self.persistent_count;
        self.persistent[idx] = mesh;
        self.persistent_hashes[idx] = hash;
        self.persistent_count += 1;

        return MeshRef{ .persistent = @intCast(idx) };
    }

    /// Allocate frame-local mesh (reset each frame)
    pub fn allocateFrame(self: *MeshPool, mesh: PathMesh) error{FrameMeshPoolFull}!MeshRef {
        if (self.frame_count >= MAX_FRAME_MESHES) {
            return error.FrameMeshPoolFull;
        }
        const idx = self.frame_count;
        self.frame_meshes[idx] = mesh;
        self.frame_count += 1;
        return MeshRef{ .frame = @intCast(idx) };
    }

    /// Get mesh by reference
    pub fn getMesh(self: *const MeshPool, ref: MeshRef) *const PathMesh {
        return switch (ref) {
            .persistent => |i| &self.persistent[i],
            .frame => |i| &self.frame_meshes[i],
        };
    }

    /// Call at frame start to reset scratch allocator
    pub fn resetFrame(self: *MeshPool) void {
        self.frame_count = 0;
    }

    /// Clear persistent cache (e.g., on theme change)
    pub fn clearPersistent(self: *MeshPool) void {
        self.persistent_count = 0;
        @memset(&self.persistent_hashes, 0);
    }
};
```

### 0.5 PathInstance — Scene Primitive

New file `src/scene/path_instance.zig`:

```gooey/src/scene/path_instance.zig#L1-65
//! PathInstance - GPU instance data for triangulated path rendering

const std = @import("std");
const scene = @import("scene.zig");
const MeshRef = @import("mesh_pool.zig").MeshRef;

pub const PathInstance = extern struct {
    // Draw order for z-index interleaving
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    // Transform: position offset
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    // Transform: scale
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    // Mesh reference (stored as u32 for GPU compatibility)
    mesh_ref_type: u32 = 0, // 0 = persistent, 1 = frame
    mesh_ref_index: u32 = 0,

    // Vertex range in shared buffer
    vertex_offset: u32 = 0,
    index_offset: u32 = 0,
    index_count: u32 = 0,
    _pad1: u32 = 0,

    // Fill color (HSLA)
    fill_color: scene.Hsla = scene.Hsla.black,

    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn init(
        mesh_ref: MeshRef,
        offset_x: f32,
        offset_y: f32,
        fill: scene.Hsla,
    ) PathInstance {
        std.debug.assert(!std.math.isNan(offset_x));
        std.debug.assert(!std.math.isNan(offset_y));

        return .{
            .mesh_ref_type = switch (mesh_ref) {
                .persistent => 0,
                .frame => 1,
            },
            .mesh_ref_index = mesh_ref.index(),
            .offset_x = offset_x,
            .offset_y = offset_y,
            .fill_color = fill,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(PathInstance) == 80);
}
```

### 0.6 Pipeline Integration

Add to `Scene`:

```gooey/src/scene/scene.zig#L470-530
// Add to Scene struct fields:
path_instances: BoundedArray(PathInstance, MAX_PATHS_PER_FRAME),
mesh_pool: MeshPool,
needs_sort_paths: bool = false,

pub const MAX_PATHS_PER_FRAME = 4096;

// Add methods:
pub fn insertPath(self: *Scene, instance: PathInstance) !void {
    std.debug.assert(self.path_instances.len < MAX_PATHS_PER_FRAME);

    var inst = instance;
    inst.order = self.reserveOrder();

    if (self.hasActiveClip()) {
        const clip = self.currentClip();
        inst.clip_x = clip.x;
        inst.clip_y = clip.y;
        inst.clip_width = clip.width;
        inst.clip_height = clip.height;
    }

    self.path_instances.appendAssumeCapacity(inst);
}

pub fn insertPathWithMesh(
    self: *Scene,
    mesh: PathMesh,
    base_instance: PathInstance,
) !void {
    // Allocate mesh in frame pool
    const mesh_ref = try self.mesh_pool.allocateFrame(mesh);

    var inst = base_instance;
    inst.mesh_ref_type = switch (mesh_ref) { .persistent => 0, .frame => 1 };
    inst.mesh_ref_index = mesh_ref.index();

    try self.insertPath(inst);
}

pub fn getPathInstances(self: *const Scene) []const PathInstance {
    return self.path_instances.constSlice();
}

pub fn resetFrame(self: *Scene) void {
    self.path_instances.len = 0;
    self.mesh_pool.resetFrame();
    // ... other frame reset logic
}
```

---

## Phase 1: Path Builder API ✅ COMPLETE

**Priority: 🔴 P0 | Effort: Low | Impact: High**

_Depends on: Phase 0_

> **Implementation Complete:** See `src/core/path.zig` and `src/core/path_test.zig`

### 1.1 Builder Pattern API ✅

**Actual implementation** in `src/core/path.zig`:

````gooey/src/core/path.zig#L1-50
//! Path Builder API
//!
//! Programmatic path construction using a fluent builder pattern.
//! Converts to meshes for GPU rendering via existing SVG infrastructure.
//!
//! ## Usage
//! ```zig
//! var path = Path.init();
//! path.moveTo(0, 0)
//!     .lineTo(100, 0)
//!     .lineTo(100, 100)
//!     .lineTo(0, 100)
//!     .closePath();
//!
//! const mesh = try path.toMesh(allocator, 0.5);
//! try scene.insertPathWithMesh(mesh, 0, 0, Hsla.red);
//! ```

const std = @import("std");
const triangulator = @import("triangulator.zig");
const path_mesh = @import("../scene/path_mesh.zig");
const mesh_pool = @import("../scene/mesh_pool.zig");

// Constants (static allocation per CLAUDE.md)
pub const MAX_PATH_COMMANDS: u32 = 2048;
pub const MAX_PATH_DATA: u32 = MAX_PATH_COMMANDS * 8;
pub const MAX_SUBPATHS: u32 = 64;

pub const Path = struct {
    commands: FixedArray(Command, MAX_PATH_COMMANDS),
    data: FixedArray(f32, MAX_PATH_DATA),
    subpath_starts: FixedArray(u32, MAX_SUBPATHS),
    current: Vec2,
    subpath_start: Vec2,
    has_current: bool,

    pub fn init() Self { ... }
    pub fn reset(self: *Self) void { ... }

    // Fluent builder methods (return *Self for chaining)
    pub fn moveTo(self: *Self, x: f32, y: f32) *Self { ... }
    pub fn lineTo(self: *Self, x: f32, y: f32) *Self { ... }
    pub fn quadTo(self: *Self, cx: f32, cy: f32, x: f32, y: f32) *Self { ... }
    pub fn cubicTo(self: *Self, cx1: f32, cy1: f32, cx2: f32, cy2: f32, x: f32, y: f32) *Self { ... }
    pub fn arcTo(self: *Self, rx: f32, ry: f32, x_rot: f32, large: bool, sweep: bool, x: f32, y: f32) *Self { ... }
    pub fn closePath(self: *Self) *Self { ... }

    // Convenience shapes
    pub fn rect(self: *Self, x: f32, y: f32, w: f32, h: f32) *Self { ... }
    pub fn roundedRect(self: *Self, x: f32, y: f32, w: f32, h: f32, r: f32) *Self { ... }
    pub fn circle(self: *Self, cx: f32, cy: f32, r: f32) *Self { ... }
    pub fn ellipse(self: *Self, cx: f32, cy: f32, rx: f32, ry: f32) *Self { ... }
};
````

### 1.2 Path → Mesh Conversion ✅

**Actual implementation** in `src/core/path.zig`:

```gooey/src/core/path.zig#L354-400
pub const PathError = error{
    TooManyCommands,
    TooManyDataFloats,
    TooManySubpaths,
    EmptyPath,
    NoCurrentPoint,
    OutOfMemory,
} || path_mesh.PathMeshError;

/// Convert path to mesh for GPU rendering
/// Uses temporary allocator for flattening, result is self-contained
pub fn toMesh(self: *const Self, allocator: std.mem.Allocator, tolerance: f32) PathError!PathMesh {
    if (self.commands.len == 0) return error.EmptyPath;

    // Flatten curves to line segments
    var points: std.ArrayList(Vec2) = .{};
    defer points.deinit(allocator);
    var polygons: std.ArrayList(triangulator.IndexSlice) = .{};
    defer polygons.deinit(allocator);

    try self.flatten(allocator, tolerance, &points, &polygons);

    if (points.items.len < 3 or polygons.items.len == 0) {
        return error.EmptyPath;
    }

    return PathMesh.fromFlattenedPath(points.items, polygons.items);
}

/// Convert path to cached mesh (returns existing if already cached)
pub fn toCachedMesh(self: *const Self, pool: *MeshPool, allocator: std.mem.Allocator, tolerance: f32) PathError!MeshRef {
    const h = self.hash();
    if (pool.hasPersistent(h)) { /* return cached */ }
    const mesh = try self.toMesh(allocator, tolerance);
    return pool.getOrCreatePersistent(mesh, h);
}

/// Compute hash for cache lookup (FNV-1a)
pub fn hash(self: *const Self) u64 {
    // Hash commands and data floats, never returns 0
}
```

**Key differences from plan:**

- Uses `std.ArrayList` for temporary storage during flattening (Zig 0.15 API)
- Self-contained curve flattening via recursive subdivision
- FNV-1a hash instead of Wyhash

---

## Phase 2: Canvas Element

**Priority: 🟡 P1 | Effort: Low | Impact: High**

_Depends on: Phase 1_

### 2.1 DrawContext

```gooey/src/ui/canvas.zig#L1-130
//! Canvas - Low-level custom drawing element
//!
//! Provides a callback-based API for custom vector graphics within
//! the Gooey UI tree.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("mod.zig");
const scene = @import("../scene/mod.zig");
const path_mod = @import("../core/path.zig");
const MeshPool = @import("../scene/mesh_pool.zig").MeshPool;
const MeshRef = @import("../scene/mesh_pool.zig").MeshRef;
const PathMesh = @import("../scene/path_mesh.zig").PathMesh;

pub const Path = path_mod.Path;

/// Cached path for repeated drawing (avoids re-tessellation)
pub const CachedPath = struct {
    mesh_ref: MeshRef,
    bounds: scene.Bounds,
};

/// Drawing context passed to canvas paint callbacks
pub const DrawContext = struct {
    scn: *scene.Scene,
    bounds: scene.Bounds,
    scale: f32,

    // ═══════════════════════════════════════════════════════════════════
    // Immediate Mode API (simple, tessellates every call)
    // ═══════════════════════════════════════════════════════════════════

    /// Fill a rectangle
    pub fn fillRect(self: *DrawContext, x: f32, y: f32, w: f32, h: f32, color: ui.Color) void {
        const quad = scene.Quad.filled(
            self.bounds.x + x,
            self.bounds.y + y,
            w, h,
            scene.Hsla.fromColor(color),
        );
        self.scn.insertQuad(quad) catch {};
    }

    /// Stroke a rectangle
    pub fn strokeRect(self: *DrawContext, x: f32, y: f32, w: f32, h: f32, color: ui.Color, width: f32) void {
        const quad = scene.Quad.filled(
            self.bounds.x + x,
            self.bounds.y + y,
            w, h,
            scene.Hsla.transparent,
        ).withBorder(scene.Hsla.fromColor(color), width);
        self.scn.insertQuad(quad) catch {};
    }

    /// Begin a new path
    pub fn beginPath(_: *DrawContext, x: f32, y: f32) Path {
        return Path.init(x, y);
    }

    /// Fill a path (immediate mode - tessellates every call)
    pub fn fillPath(self: *DrawContext, p: *const Path, color: ui.Color) void {
        const mesh = p.toMesh(0.5 / self.scale) catch |err| {
            if (builtin.mode == .Debug) {
                std.log.warn("Path tessellation failed: {}, skipping", .{err});
            }
            return;
        };
        var instance = scene.PathInstance.init(
            MeshRef{ .frame = 0 }, // Will be assigned by scene
            self.bounds.x,
            self.bounds.y,
            scene.Hsla.fromColor(color),
        );
        self.scn.insertPathWithMesh(mesh, instance) catch {};
    }

    /// Draw a filled circle
    pub fn fillCircle(self: *DrawContext, cx: f32, cy: f32, r: f32, color: ui.Color) void {
        var p = self.beginPath(cx + r, cy);
        // Approximate circle with 4 cubic beziers (magic number for circle approximation)
        const k: f32 = 0.552284749831;
        _ = p.cubicTo(cx + r, cy + r * k, cx + r * k, cy + r, cx, cy + r)
             .cubicTo(cx - r * k, cy + r, cx - r, cy + r * k, cx - r, cy)
             .cubicTo(cx - r, cy - r * k, cx - r * k, cy - r, cx, cy - r)
             .cubicTo(cx + r * k, cy - r, cx + r, cy - r * k, cx + r, cy)
             .close();
        self.fillPath(&p, color);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Cached Mode API (for repeated draws of same path)
    // ═══════════════════════════════════════════════════════════════════

    /// Cache a path for repeated drawing (avoids re-tessellation)
    /// Returns null if tessellation fails
    pub fn cachePath(self: *DrawContext, p: *const Path) ?CachedPath {
        const mesh = p.toMesh(0.5 / self.scale) catch return null;
        const mesh_ref = self.scn.mesh_pool.allocateFrame(mesh) catch return null;
        return CachedPath{ .mesh_ref = mesh_ref, .bounds = mesh.bounds };
    }

    /// Fill a previously cached path (no tessellation, very fast)
    pub fn fillCached(self: *DrawContext, cached: CachedPath, color: ui.Color) void {
        const instance = scene.PathInstance.init(
            cached.mesh_ref,
            self.bounds.x,
            self.bounds.y,
            scene.Hsla.fromColor(color),
        );
        self.scn.insertPath(instance) catch {};
    }

    // ═══════════════════════════════════════════════════════════════════
    // Static Path API (for icons and compile-time known paths)
    // ═══════════════════════════════════════════════════════════════════

    /// Fill a static path by hash (persistent cache, survives across frames)
    /// Use for icons and other paths that don't change
    pub fn fillStaticPath(
        self: *DrawContext,
        p: *const Path,
        color: ui.Color,
    ) void {
        const hash = p.hash();

        // Try to get from persistent cache
        const mesh = p.toMesh(0.5 / self.scale) catch return;
        const mesh_ref = self.scn.mesh_pool.getOrCreatePersistent(mesh, hash) catch {
            // Cache full, fall back to frame allocation
            const frame_ref = self.scn.mesh_pool.allocateFrame(mesh) catch return;
            const instance = scene.PathInstance.init(frame_ref, self.bounds.x, self.bounds.y, scene.Hsla.fromColor(color));
            self.scn.insertPath(instance) catch {};
            return;
        };

        const instance = scene.PathInstance.init(mesh_ref, self.bounds.x, self.bounds.y, scene.Hsla.fromColor(color));
        self.scn.insertPath(instance) catch {};
    }
};
```

### 2.2 Canvas Component

```gooey/src/ui/canvas.zig#L135-180
/// Canvas element for custom drawing
pub const Canvas = struct {
    width: f32,
    height: f32,
    paint: *const fn (*DrawContext) void,

    pub fn render(self: Canvas, b: *ui.Builder) void {
        // Reserve space in layout
        b.box(.{
            .width = self.width,
            .height = self.height,
        }, .{
            CanvasPrimitive{
                .width = self.width,
                .height = self.height,
                .paint = self.paint,
            },
        });
    }
};

/// Internal primitive for deferred canvas rendering
pub const CanvasPrimitive = struct {
    width: f32,
    height: f32,
    paint: *const fn (*DrawContext) void,

    /// Called by renderer after layout is complete
    pub fn execute(
        self: CanvasPrimitive,
        s: *scene.Scene,
        bounds: scene.Bounds,
        scale: f32,
    ) void {
        var ctx = DrawContext{
            .scn = s,
            .bounds = bounds,
            .scale = scale,
        };
        self.paint(&ctx);
    }
};
```

### 2.3 Usage Example

```gooey/dev/null/canvas_example.zig#L1-45
fn myCanvasPaint(ctx: *ui.DrawContext) void {
    // Background
    ctx.fillRect(0, 0, 200, 200, .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 });

    // Custom path: star shape
    var star = ctx.beginPath(100, 10);
    _ = star.lineTo(120, 80)
            .lineTo(190, 80)
            .lineTo(130, 120)
            .lineTo(150, 190)
            .lineTo(100, 150)
            .lineTo(50, 190)
            .lineTo(70, 120)
            .lineTo(10, 80)
            .lineTo(80, 80)
            .close();
    ctx.fillPath(&star, ui.Color.gold);

    // Circle
    ctx.fillCircle(100, 100, 30, ui.Color.red);
}

// Example: Using cached paths for performance (e.g., in a chart)
fn chartPaint(ctx: *ui.DrawContext) void {
    // Cache the bar shape once
    var bar = ctx.beginPath(0, 0);
    _ = bar.lineTo(20, 0).lineTo(20, 100).lineTo(0, 100).close();

    const cached = ctx.cachePath(&bar) orelse return;

    // Draw 50 bars with different colors - only 1 tessellation!
    for (0..50) |i| {
        const x = @as(f32, @floatFromInt(i)) * 25;
        const color = ui.Color{ .r = @as(f32, @floatFromInt(i)) / 50.0, .g = 0.5, .b = 0.8, .a = 1 };
        // Note: Would need transform support for proper positioning
        ctx.fillCached(cached, color);
    }
}

// In your UI:
pub fn view(b: *ui.Builder) void {
    ui.Canvas{
        .width = 200,
        .height = 200,
        .paint = myCanvasPaint,
    }.render(b);
}
```

---

## Phase 3: Gradients

**Priority: 🟡 P1 | Effort: Medium | Impact: High**

_Depends on: Phase 1_

### 3.1 Gradient Types

```gooey/src/core/gradient.zig#L1-65
//! Gradients for path and shape fills
//!
//! Note: Maximum 16 color stops supported per gradient.

const std = @import("std");
const Color = @import("../layout/types.zig").Color;

/// Maximum gradient color stops (documented limit)
pub const MAX_GRADIENT_STOPS = 16;

pub const ColorStop = struct {
    offset: f32, // 0.0 - 1.0
    color: Color,
};

pub const LinearGradient = struct {
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    stops: []const ColorStop,

    pub fn horizontal(stops: []const ColorStop) LinearGradient {
        std.debug.assert(stops.len >= 2);
        std.debug.assert(stops.len <= MAX_GRADIENT_STOPS);
        return .{ .start_x = 0, .start_y = 0.5, .end_x = 1, .end_y = 0.5, .stops = stops };
    }

    pub fn vertical(stops: []const ColorStop) LinearGradient {
        std.debug.assert(stops.len >= 2);
        std.debug.assert(stops.len <= MAX_GRADIENT_STOPS);
        return .{ .start_x = 0.5, .start_y = 0, .end_x = 0.5, .end_y = 1, .stops = stops };
    }

    pub fn diagonal(stops: []const ColorStop) LinearGradient {
        std.debug.assert(stops.len >= 2);
        std.debug.assert(stops.len <= MAX_GRADIENT_STOPS);
        return .{ .start_x = 0, .start_y = 0, .end_x = 1, .end_y = 1, .stops = stops };
    }
};

pub const RadialGradient = struct {
    center_x: f32, // 0.0 - 1.0 (relative to bounds)
    center_y: f32,
    radius: f32,   // 0.0 - 1.0 (relative to bounds)
    stops: []const ColorStop,

    pub fn centered(radius: f32, stops: []const ColorStop) RadialGradient {
        std.debug.assert(stops.len >= 2);
        std.debug.assert(stops.len <= MAX_GRADIENT_STOPS);
        return .{ .center_x = 0.5, .center_y = 0.5, .radius = radius, .stops = stops };
    }
};

pub const Fill = union(enum) {
    solid: Color,
    linear: LinearGradient,
    radial: RadialGradient,
};
```

### 3.2 Gradient Uniforms (GPU-side)

```gooey/src/core/gradient.zig#L70-95
/// GPU-compatible gradient uniforms struct
/// Must match shader layout exactly
pub const GradientUniforms = extern struct {
    start: [2]f32,
    end: [2]f32,
    colors: [MAX_GRADIENT_STOPS][4]f32,
    offsets: [MAX_GRADIENT_STOPS]f32,
    stop_count: u32,
    gradient_type: u32, // 0=solid, 1=linear, 2=radial
    _pad: [2]f32 = .{ 0, 0 },
};

comptime {
    // Ensure 16-byte alignment for GPU
    std.debug.assert(@sizeOf(GradientUniforms) % 16 == 0);
}
```

### 3.3 Gradient Shader Support

```gooey/src/platform/mac/metal/shaders/path.metal#L1-55
// Gradient uniforms - must match Zig struct layout
struct GradientUniforms {
    float2 start;
    float2 end;
    float4 colors[16];  // 16 color stops max
    float offsets[16];
    uint stop_count;
    uint gradient_type; // 0=solid, 1=linear, 2=radial
    float2 _pad;
};

fragment float4 path_fragment(
    PathVertexOut in [[stage_in]],
    constant GradientUniforms& gradient [[buffer(0)]]
) {
    if (gradient.gradient_type == 0) {
        // Solid color
        return in.color;
    }

    float t;
    if (gradient.gradient_type == 1) {
        // Linear gradient
        float2 dir = gradient.end - gradient.start;
        float2 pos = in.uv - gradient.start;
        t = dot(pos, dir) / dot(dir, dir);
    } else {
        // Radial gradient
        float2 center = gradient.start;
        float radius = length(gradient.end - gradient.start);
        t = length(in.uv - center) / radius;
    }

    t = clamp(t, 0.0, 1.0);

    // Find color stops and interpolate
    float4 color = gradient.colors[0];
    for (uint i = 1; i < gradient.stop_count; i++) {
        if (t >= gradient.offsets[i-1] && t <= gradient.offsets[i]) {
            float local_t = (t - gradient.offsets[i-1]) / (gradient.offsets[i] - gradient.offsets[i-1]);
            color = mix(gradient.colors[i-1], gradient.colors[i], local_t);
            break;
        }
    }

    return color;
}
```

### 3.4 Path Pipeline MSAA Integration

The path pipeline integrates with existing MSAA infrastructure — no additional setup required:

**Metal (src/platform/mac/metal/pipelines.zig):**

```gooey/src/platform/mac/metal/pipelines.zig#L300-320
pub fn setupPathPipeline(
    device: objc.Object,
    library: objc.Object,
    sample_count: u32,  // Uses same MSAA sample count as quads
) !objc.Object {
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "new", .{});
    defer desc.msgSend(void, "release", .{});

    // ... vertex/fragment function setup ...

    // CRITICAL: Match MSAA sample count with render pass
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    // Color attachment with standard alpha blending
    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8_unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    // ... blend state matches existing quad pipeline ...
}
```

**WebGPU (src/platform/wgpu/web/renderer.zig):**

```gooey/src/platform/wgpu/web/renderer.zig#L275-285
// Path pipeline created with same MSAA sample count as other pipelines
if (self.sample_count > 1) {
    self.path_pipeline = imports.createMSAARenderPipeline(
        path_module, "vs_main", 7, "fs_main", 7, self.sample_count
    );
} else {
    self.path_pipeline = imports.createRenderPipeline(
        path_module, "vs_main", 7, "fs_main", 7
    );
}
```

**Why this works:**

1. All pipelines share the same `sample_count` (typically 4)
2. All render to the same MSAA texture (`msaa_texture`)
3. MSAA resolve happens once at frame end → drawable/swapchain
4. Paths get anti-aliased triangle edges "for free"

**Memory cost:** Zero additional — MSAA texture already allocated for quads/shadows.

---

## Phase 4: Stroke Rendering

**Priority: 🟡 P1 | Effort: Medium | Impact: Medium**

_Depends on: Phase 0_

### Anti-Aliasing for Strokes

Strokes benefit from the same anti-aliasing infrastructure as fills:

1. **MSAA (4x)** — Handles stroke edge aliasing automatically
2. **Expansion tessellation** — Stroke expanded to filled polygon, rendered as triangles
3. **Miter/bevel/round joins** — Tessellated at CPU, MSAA smooths the result

For most UI strokes (1-4px), MSAA provides excellent quality without needing SDF strokes.

**When to consider SDF strokes (future Phase 5):**

- Animated stroke widths (avoid re-tessellation)
- Very thin strokes (<1px) that need sub-pixel rendering
- Dashed/dotted patterns with per-dash anti-aliasing

### 4.1 Path Stroking via Expansion

```gooey/src/core/stroke.zig#L1-100
//! Path stroke expansion - converts stroke to filled path
//!
//! Strokes are rendered by expanding the path into a filled outline,
//! then using the same tessellation pipeline as fills.

const std = @import("std");
const triangulator = @import("triangulator.zig");
const Vec2 = triangulator.Vec2;
const IndexSlice = triangulator.IndexSlice;
const BoundedArray = std.BoundedArray;

pub const MAX_STROKE_VERTICES = 8192;
pub const MAX_STROKE_POLYGONS = 256;

pub const StrokeStyle = struct {
    width: f32 = 1.0,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
};

pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };

pub const StrokeError = error{
    TooManyVertices,
    TooManyPolygons,
    DegeneratePath,
};

/// Expand a path's stroke to a filled outline
pub fn expandStroke(
    points: []const Vec2,
    polygons: []const IndexSlice,
    style: StrokeStyle,
    out_points: *BoundedArray(Vec2, MAX_STROKE_VERTICES),
    out_polygons: *BoundedArray(IndexSlice, MAX_STROKE_POLYGONS),
) StrokeError!void {
    const half_width = style.width / 2.0;

    for (polygons) |poly| {
        const pts = points[poly.start..poly.end];
        if (pts.len < 2) continue;

        // Check capacity before processing
        if (out_points.len + pts.len * 2 > MAX_STROKE_VERTICES) {
            return error.TooManyVertices;
        }
        if (out_polygons.len >= MAX_STROKE_POLYGONS) {
            return error.TooManyPolygons;
        }

        const out_start: u32 = @intCast(out_points.len);

        // Generate outer edge
        for (0..pts.len) |i| {
            const p0 = if (i == 0) pts[pts.len - 1] else pts[i - 1];
            const p1 = pts[i];
            const p2 = if (i == pts.len - 1) pts[0] else pts[i + 1];

            const n = calculateMiterNormal(p0, p1, p2, style.miter_limit);
            out_points.appendAssumeCapacity(.{
                .x = p1.x + n.x * half_width,
                .y = p1.y + n.y * half_width,
            });
        }

        // Generate inner edge (reversed winding)
        for (0..pts.len) |j| {
            const i = pts.len - 1 - j;
            const p0 = if (i == 0) pts[pts.len - 1] else pts[i - 1];
            const p1 = pts[i];
            const p2 = if (i == pts.len - 1) pts[0] else pts[i + 1];

            const n = calculateMiterNormal(p0, p1, p2, style.miter_limit);
            out_points.appendAssumeCapacity(.{
                .x = p1.x - n.x * half_width,
                .y = p1.y - n.y * half_width,
            });
        }

        const out_end: u32 = @intCast(out_points.len);
        out_polygons.appendAssumeCapacity(.{ .start = out_start, .end = out_end });
    }
}

fn calculateMiterNormal(p0: Vec2, p1: Vec2, p2: Vec2, miter_limit: f32) Vec2 {
    const n1 = perpendicular(Vec2{ .x = p1.x - p0.x, .y = p1.y - p0.y });
    const n2 = perpendicular(Vec2{ .x = p2.x - p1.x, .y = p2.y - p1.y });

    const n1_norm = normalize(n1);
    const n2_norm = normalize(n2);

    // Average normal
    var n = Vec2{ .x = n1_norm.x + n2_norm.x, .y = n1_norm.y + n2_norm.y };
    n = normalize(n);

    // Miter scale (clamped to limit)
    const dot_val = n.x * n1_norm.x + n.y * n1_norm.y;
    const miter_scale = 1.0 / @max(0.1, dot_val);
    const effective_scale = @min(miter_scale, miter_limit);

    return Vec2{ .x = n.x * effective_scale, .y = n.y * effective_scale };
}

fn perpendicular(v: Vec2) Vec2 {
    return .{ .x = -v.y, .y = v.x };
}

fn normalize(v: Vec2) Vec2 {
    const len = @sqrt(v.x * v.x + v.y * v.y);
    if (len < 0.0001) return .{ .x = 0, .y = 0 };
    return .{ .x = v.x / len, .y = v.y / len };
}
```

### 4.2 Path API Stroke Method

Add to `src/core/path.zig`:

```gooey/src/core/path.zig#L185-230
    /// Stroke this path with given style
    pub fn toStrokeMesh(
        self: *const Path,
        style: stroke_mod.StrokeStyle,
        tolerance: f32,
    ) ConversionError!PathMesh {
        // First flatten the path
        var points: std.BoundedArray(triangulator.Vec2, triangulator.MAX_PATH_VERTICES) = .{};
        var polygons: std.BoundedArray(triangulator.IndexSlice, 64) = .{};

        const svg_path = self.toSvgPath();
        svg.flattenPathView(&svg_path, tolerance, &points, &polygons) catch {
            return error.PathTooComplex;
        };

        // Expand stroke to filled outline
        var stroke_points: std.BoundedArray(triangulator.Vec2, stroke_mod.MAX_STROKE_VERTICES) = .{};
        var stroke_polygons: std.BoundedArray(triangulator.IndexSlice, stroke_mod.MAX_STROKE_POLYGONS) = .{};

        stroke_mod.expandStroke(
            points.constSlice(),
            polygons.constSlice(),
            style,
            &stroke_points,
            &stroke_polygons,
        ) catch {
            return error.PathTooComplex;
        };

        // Triangulate the stroke outline
        return PathMesh.fromFlattenedPath(
            stroke_points.constSlice(),
            stroke_polygons.constSlice(),
        ) catch |err| {
            return switch (err) {
                error.TooManyVertices => error.TooManyVertices,
                error.TooManyIndices => error.TooManyIndices,
                error.DegeneratePolygon => error.DegeneratePolygon,
                error.EarClippingFailed => error.EarClippingFailed,
            };
        };
    }
```

---

## Implementation Roadmap

```gooey/dev/null/roadmap.md#L1-70
# Gooey Path/Canvas Roadmap

## Week 1-2: Phase 0 (GPU Tessellation)
- [ ] Implement ear-clipping triangulator with winding detection
- [ ] Create PathMesh struct with UV generation
- [ ] Implement MeshPool (two-tier caching)
- [ ] Add PathInstance to Scene
- [ ] Create path render pipeline for Metal (use existing sample_count)
- [ ] Create path render pipeline for WebGPU (use existing sample_count)
- [x] **MSAA Integration**: Verify paths render to existing msaa_texture
- [x] **MSAA Integration**: Confirm MSAA resolve includes path triangles
- [x] Tests: triangulation correctness, winding, degenerate cases
- [x] Tests: visual comparison with/without MSAA (should see smooth edges)

## Week 3: Phase 1 (Path Builder) ✅ COMPLETE
- [x] Implement Path builder API (fluent pattern with method chaining)
- [x] Self-contained curve flattening (quadratic, cubic, arc)
- [x] Path.toMesh() with proper error handling
- [x] Path.hash() for cache keys (FNV-1a)
- [x] Convenience shapes: rect(), roundedRect(), circle(), ellipse()
- [x] Path.toCachedMesh() for persistent caching
- [x] Tests: builder patterns, complex paths, error cases (35+ tests)

## Week 4: Phase 2 (Canvas)
- [ ] DrawContext with immediate + cached APIs
- [ ] Canvas component
- [ ] CanvasPrimitive deferred execution
- [ ] Integration with layout system
- [ ] Example: custom chart component with caching

## Week 5-6: Phase 3 (Gradients)
- [ ] Gradient types (linear, radial) with 16 stop limit
- [ ] GradientUniforms struct (GPU-compatible)
- [ ] Metal gradient shader
- [ ] WebGPU gradient shader
- [ ] DrawContext.fillGradient()

## Week 7: Phase 4 (Strokes)
- [ ] Stroke expansion algorithm
- [ ] Miter limit handling
- [ ] Path.toStrokeMesh() method
- [ ] DrawContext.strokePath()
- [ ] Tests: stroke correctness, miter limits

## Week 8+ (Optional): Phase 5 (SDF Edge Feathering)
- [ ] Add barycentric coordinates to PathVertex
- [ ] Compute barycentrics in vertex shader
- [ ] path_fragment_feathered() with smoothstep edge falloff
- [ ] PathInstance.feather_edges flag (default: false)
- [ ] Tests: visual comparison at 0.5x scale with/without feathering
- [ ] Performance benchmark: measure fragment shader overhead

**Phase 5 triggers** (implement when needed):
- Icons rendered at <1x scale show visible aliasing
- Animated morphing paths have flickering edges
- Data visualization thin lines need sub-pixel precision
```

---

## File Structure

```gooey/dev/null/file_structure.md#L1-30
src/
├── core/
│   ├── svg.zig              # Existing - path parsing/flattening
│   ├── triangulator.zig     # ✅ DONE - ear-clipping with winding detection
│   ├── path.zig             # ✅ DONE - Path builder API
│   ├── path_test.zig        # ✅ DONE - 35+ path builder tests
│   ├── stroke.zig           # NEW - Stroke expansion
│   └── gradient.zig         # NEW - Gradient types
│
├── scene/
│   ├── scene.zig            # ✅ DONE - path_instances, mesh_pool added
│   ├── path_mesh.zig        # ✅ DONE - GPU mesh struct
│   ├── path_instance.zig    # ✅ DONE - Instance data
│   └── mesh_pool.zig        # ✅ DONE - Two-tier caching (lazy heap alloc)
│
├── ui/
│   └── canvas.zig           # NEW - Canvas component + DrawContext
│
└── platform/
    ├── mac/metal/
    │   ├── path_pipeline.zig # ✅ DONE - path pipeline + embedded shader
    │   └── renderer.zig      # ✅ DONE - path rendering integration
    └── wgpu/
        ├── shaders/
        │   └── path.wgsl     # ✅ DONE - WebGPU path shaders
        └── web/renderer.zig  # ✅ DONE - WebGPU path rendering
```

---

## Testing Strategy

```gooey/src/core/triangulator_test.zig#L1-80
const std = @import("std");
const triangulator = @import("triangulator.zig");

test "Triangulator produces correct triangle count for square" {
    // Square: 4 vertices → 2 triangles → 6 indices
    const points = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    const poly = triangulator.IndexSlice{ .start = 0, .end = 4 };

    var tri = triangulator.Triangulator.init();
    const indices = try tri.triangulate(&points, poly);

    try std.testing.expectEqual(@as(usize, 6), indices.len);
}

test "Triangulator handles CCW winding" {
    // CCW square
    const points = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    const poly = triangulator.IndexSlice{ .start = 0, .end = 4 };

    var tri = triangulator.Triangulator.init();
    _ = try tri.triangulate(&points, poly);

    try std.testing.expect(tri.is_ccw);
}

test "Triangulator handles CW winding" {
    // CW square (reversed)
    const points = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 0 },
    };
    const poly = triangulator.IndexSlice{ .start = 0, .end = 4 };

    var tri = triangulator.Triangulator.init();
    _ = try tri.triangulate(&points, poly);

    try std.testing.expect(!tri.is_ccw);
}

test "Triangulator handles concave polygon" {
    // L-shape: 6 vertices → 4 triangles → 12 indices
    const points = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    const poly = triangulator.IndexSlice{ .start = 0, .end = 6 };

    var tri = triangulator.Triangulator.init();
    const indices = try tri.triangulate(&points, poly);

    try std.testing.expectEqual(@as(usize, 12), indices.len);
}

test "Triangulator rejects degenerate polygon" {
    // Only 2 points - not a valid polygon
    const points = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
    };
    const poly = triangulator.IndexSlice{ .start = 0, .end = 2 };

    var tri = triangulator.Triangulator.init();
    const result = tri.triangulate(&points, poly);

    try std.testing.expectError(error.DegeneratePolygon, result);
}

test "Triangulator rejects too many vertices" {
    // Exceeds MAX_PATH_VERTICES
    var tri = triangulator.Triangulator.init();
    const points = [_]triangulator.Vec2{.{ .x = 0, .y = 0 }} ** (triangulator.MAX_PATH_VERTICES + 1);
    const poly = triangulator.IndexSlice{ .start = 0, .end = triangulator.MAX_PATH_VERTICES + 1 };

    const result = tri.triangulate(&points, poly);
    try std.testing.expectError(error.TooManyVertices, result);
}
```

```gooey/src/scene/mesh_pool_test.zig#L1-40
const std = @import("std");
const MeshPool = @import("mesh_pool.zig").MeshPool;
const PathMesh = @import("path_mesh.zig").PathMesh;

test "MeshPool persistent cache hit" {
    var pool = MeshPool.init();
    const mesh = PathMesh.init();

    const ref1 = try pool.getOrCreatePersistent(mesh, 12345);
    const ref2 = try pool.getOrCreatePersistent(mesh, 12345);

    // Same hash should return same reference
    try std.testing.expectEqual(ref1.persistent, ref2.persistent);
    try std.testing.expectEqual(@as(u32, 1), pool.persistent_count);
}

test "MeshPool frame reset" {
    var pool = MeshPool.init();
    const mesh = PathMesh.init();

    _ = try pool.allocateFrame(mesh);
    _ = try pool.allocateFrame(mesh);
    try std.testing.expectEqual(@as(u32, 2), pool.frame_count);

    pool.resetFrame();
    try std.testing.expectEqual(@as(u32, 0), pool.frame_count);
}
```

---

## Summary: Dependency Graph

```gooey/dev/null/dependencies.txt#L1-35
Phase 0: GPU Tessellation ✅ COMPLETE
    ├── Triangulator (ear-clipping + winding detection) ✅
    ├── PathMesh (vertices + indices + UVs) ✅
    ├── MeshPool (persistent + per-frame caching) ✅
    ├── PathInstance (scene primitive) ✅
    └── Path pipelines (Metal/WebGPU) ─── uses existing MSAA texture ✅
          │
          ▼
Phase 1: Path Builder ✅ COMPLETE ───────┐
    ├── Path struct (fluent API) ✅       │
    ├── toMesh() + toCachedMesh() ✅      │
    ├── hash() for cache keys (FNV-1a) ✅ │
    └── Convenience shapes ✅             │
          │                              │
          ▼                              │
Phase 2: Canvas ◄────────────────────────┘ 🔲 NEXT
    ├── DrawContext (immediate + cached + static APIs)
    └── Canvas component
          │
          ├──────────────┬───────────────┐
          ▼              ▼               ▼
Phase 3: Gradients    Phase 4: Strokes    Phase 5: SDF Edge Feather (optional)
    ├── LinearGradient    ├── expandStroke()    ├── Barycentric coords in vertex shader
    ├── RadialGradient    ├── LineCap/LineJoin  ├── smoothstep() edge falloff
    ├── 16 stop limit     └── toStrokeMesh()    └── PathInstance.feather_edges flag
    └── Gradient shaders

Existing Infrastructure (already implemented):
    ├── 4x MSAA on Metal/WebGPU/Vulkan
    ├── rounded_rect_sdf() for quads/borders
    └── shadow_falloff() for soft shadows
```

---

## Design Decisions Summary

| Decision                          | Rationale                                                              |
| --------------------------------- | ---------------------------------------------------------------------- |
| Ear-clipping over Delaunay        | Simpler, sufficient for UI paths (<1000 verts), easier to debug        |
| Winding detection via signed area | Zero allocation, O(n), flip convexity test instead of reversing points |
| Two-tier mesh pool                | Static icons stay cached; dynamic paths reset per-frame                |
| 16 gradient stops                 | Covers 99% of use cases, keeps uniform buffer small                    |
| Stroke as expanded fill           | Reuses tessellation pipeline, no separate stroke shader                |
| Explicit errors at API boundary   | Fail fast with clear errors, assertions internally                     |
| `CachedPath` API                  | Enables charts/lists to tessellate once, draw many times               |
| **MSAA over SDF for paths**       | 4x MSAA already enabled; good tessellation + MSAA = excellent quality  |
| **Leverage existing SDF**         | Rounded rects, shadows already SDF; paths use same smoothstep pattern  |
| **Edge feathering opt-in**        | 5-10% shader cost only when needed (small scale, animations)           |
| **Share MSAA texture**            | Zero additional memory — paths render to same target as quads/shadows  |
| **Tolerance-based flattening**    | Adaptive curve subdivision ensures MSAA suffices for most curves       |

---

## Comparison with GPUI

| Feature           | Gooey (This Plan)              | GPUI                       |
| ----------------- | ------------------------------ | -------------------------- |
| Path tessellation | Ear-clipping, cached           | Per-frame tessellation     |
| Mesh caching      | Two-tier (persistent + frame)  | Implicit via retained mode |
| Anti-aliasing     | **4x MSAA + SDF hybrid**       | SDF strokes + analytic AA  |
| Stroke rendering  | Expansion → fill → MSAA        | GPU SDF strokes            |
| Memory model      | Static allocation, hard limits | Dynamic Rust `Vec`         |
| Gradient stops    | 16 max (documented)            | Unlimited (heap)           |
| Frame consistency | Predictable (no alloc jitter)  | Variable                   |

**Gooey advantages:**

- Mesh caching eliminates re-tessellation for static paths
- MSAA is "free" — already paying for it on quads/shadows
- Static allocation = predictable frame times
- **Infrastructure reuse** — paths leverage existing MSAA texture, SDF patterns, and shader infrastructure rather than building a separate path AA system

**GPUI advantages:**

- SDF strokes handle animated width without re-tessellation
- More robust complex path handling (even-odd fill, holes)

**The key difference:** GPUI built a dedicated path anti-aliasing system (SDF strokes, analytic AA). Gooey reuses what's already there — 4x MSAA handles 90% of cases, and the optional Phase 5 edge feathering (using the same `smoothstep` pattern as `rounded_rect_sdf`) covers the remaining edge cases. This means less code, less GPU memory, and fewer shader permutations to maintain.

For UI frameworks, Gooey's approach optimizes for the common case (static icons, simple shapes) while GPUI optimizes for edge cases (complex vector graphics).

---

This plan gives you a clear path from "SVG icons in atlas" to "full Canvas API" while respecting Gooey's static allocation philosophy and building each layer on solid foundations.
