# Dashed Polyline Support

Design document for adding dashed line rendering to the polyline pipeline.

---

## Current Pipeline

The polyline rendering pipeline has three layers:

1. **`DrawContext.polyline()`** (`src/ui/canvas.zig`) — transforms points to scene coordinates, creates a `Polyline` struct, inserts into the scene.
2. **`Polyline` struct** (`src/scene/polyline.zig`) — a 64-byte extern struct with points, width, color, and clip bounds. No dash information.
3. **CPU quad expansion** — both Metal (`src/platform/macos/metal/polyline_pipeline.zig`) and WebGPU (`src/platform/web/renderer.zig`) renderers walk segments and expand each into a quad (4 vertices, 6 indices).
4. **Shaders** — vertex shader transforms pre-expanded quads to NDC. Fragment shader does clip testing. No distance-along-path information exists.

```gooey/src/scene/polyline.zig#L55-65
pub const Polyline = extern struct {
    // Draw order for z-index interleaving (8 bytes with padding)
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    // Point buffer info - stored as u64 for pointer, plus count (16 bytes)
    // Note: For GPU upload, renderer will copy points to vertex buffer
    points_ptr: u64 = 0, // Pointer stored as u64 for extern struct compatibility
    point_count: u32 = 0,
    _pad1: u32 = 0,
```

The Metal quad expansion loop:

```gooey/src/platform/macos/metal/polyline_pipeline.zig#L241-273
            for (0..points.len - 1) |i| {
                const p0 = points[i];
                const p1 = points[i + 1];

                // Calculate direction and perpendicular
                const dx = p1.x - p0.x;
                const dy = p1.y - p0.y;
                const len = @sqrt(dx * dx + dy * dy);
                ...
                // Quad corners (CCW winding)
                // 0--1
                // |  |
                // 3--2
```

The WebGPU fragment shader — just clip testing, no path distance:

```gooey/src/platform/wgpu/shaders/polyline.wgsl#L72-83
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Clip test
    let clip_min = in.clip_bounds.xy;
    let clip_max = clip_min + in.clip_bounds.zw;
    if in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
       in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y {
        discard;
    }

    if in.color.a < 0.001 { discard; }
```

---

## Design: CPU-Side Dash Expansion

The cleanest approach is **CPU-side dash expansion** — no shader changes. During the quad expansion step, track cumulative distance along the polyline and only emit quads for "on" segments, skipping "off" gaps. The GPU never knows about dashes.

### Why CPU-side

- Both GPU shaders are untouched — they render pre-expanded quads as before.
- The `PolylineUniforms` structs (Metal and WebGPU) don't change — dash info is consumed during CPU expansion, not passed to GPU.
- The batch iterator, scene insertion, and z-ordering are all unchanged.
- Solid polylines (`dash_length == 0`) take the existing fast path with zero overhead.
- More quads per dashed polyline, but still a single draw call per polyline — just more vertices/indices in the same buffer.

---

## Layer 1: `Polyline` Struct — Add Dash Fields

Add `dash_length`, `gap_length`, and `dash_offset` to the `Polyline` extern struct. Zero values mean solid (backward-compatible). This bumps the struct from 64 to 80 bytes, which stays 16-byte aligned for Metal/WebGPU.

The `dash_offset` field enables animated dashes (marching ants for selections, loading indicators) by shifting the pattern along the path. Adding it now avoids a second struct layout change later.

### New fields

```/dev/null/polyline_fields.zig#L1-7
// New fields (after clip_height, before end of struct):
// Dash pattern: 0 = solid line (default), >0 = dashed.
dash_length: f32 = 0,   // Length of drawn segment in pixels.
gap_length: f32 = 0,    // Length of gap between segments in pixels.
dash_offset: f32 = 0,   // Phase offset into the pattern in pixels.
_pad3: f32 = 0,
// Total: 64 + 16 = 80 bytes (16-byte aligned).
```

### Updated comptime assertions

```/dev/null/polyline_comptime.zig#L1-7
comptime {
    if (@sizeOf(Polyline) != 80) {
        @compileError(std.fmt.comptimePrint(
            "Polyline must be 80 bytes for GPU alignment, got {}",
            .{@sizeOf(Polyline)},
        ));
    }
}
```

### Builder method

```/dev/null/polyline_builder.zig#L1-15
pub fn withDash(self: Self, dash: f32, gap: f32) Self {
    std.debug.assert(dash > 0);
    std.debug.assert(gap > 0);
    var inst = self;
    inst.dash_length = dash;
    inst.gap_length = gap;
    return inst;
}

pub fn withDashOffset(self: Self, offset: f32) Self {
    std.debug.assert(!std.math.isNan(offset));
    var inst = self;
    inst.dash_offset = offset;
    return inst;
}
```

---

## Layer 2: Shared Dash Iterator

Both Metal and WebGPU need the same dash segment iteration logic. This is pure geometry — it doesn't touch any GPU types. Extract it into `polyline.zig` as an iterator so the logic lives in one place and is unit-testable in isolation.

```/dev/null/dash_iterator.zig#L1-68
/// Iterates over visible (drawn) sub-segments of a dashed polyline.
/// Yields (p0, p1) pairs for each dash sub-segment.
///
/// Pure geometry — no GPU types. Both Metal and WebGPU renderers
/// consume this identically: call next(), compute perpendicular, emit quad.
pub const DashIterator = struct {
    points: []const scene.Point,
    dash_length: f32,
    gap_length: f32,
    period: f32,

    // Internal walk state.
    segment_index: u32,
    distance_along: f32,
    t_within_segment: f32,

    pub const SubSegment = struct {
        p0: scene.Point,
        p1: scene.Point,
    };

    pub fn init(
        points: []const scene.Point,
        dash_length: f32,
        gap_length: f32,
        dash_offset: f32,
    ) DashIterator {
        std.debug.assert(points.len >= 2);
        std.debug.assert(dash_length > 0);
        std.debug.assert(gap_length > 0);
        return .{
            .points = points,
            .dash_length = dash_length,
            .gap_length = gap_length,
            .period = dash_length + gap_length,
            .segment_index = 0,
            .distance_along = dash_offset,
            .t_within_segment = 0,
        };
    }

    pub fn next(self: *DashIterator) ?SubSegment {
        // Walk forward across segments, skip gaps, yield dash sub-segments.
        // Each call returns one drawn sub-segment or null when exhausted.
        // The perpendicular vector is constant within a parent segment,
        // so callers can cache it per segment_index.
        ...
    }

    /// Count the total number of sub-segments without emitting them.
    /// Used for pre-allocating vertex/index buffer space.
    pub fn countSubSegments(
        points: []const scene.Point,
        dash_length: f32,
        gap_length: f32,
        dash_offset: f32,
    ) u32 {
        var iter = DashIterator.init(points, dash_length, gap_length, dash_offset);
        var count: u32 = 0;
        while (iter.next() != null) : (count += 1) {}
        return count;
    }
};
```

Both renderers then consume it the same way:

```/dev/null/renderer_consumption.zig#L1-13
var iter = DashIterator.init(points, pl.dash_length, pl.gap_length, pl.dash_offset);
while (iter.next()) |sub| {
    const dx = sub.p1.x - sub.p0.x;
    const dy = sub.p1.y - sub.p0.y;
    const len = @sqrt(dx * dx + dy * dy);
    // ... same perpendicular math as solid segments ...
    // ... emit quad for (sub.p0, sub.p1) ...
}
```

### Benefits

- **Testable in isolation.** Write tests in `polyline.zig` that assert sub-segment positions without spinning up a renderer.
- **No duplication.** The ~40 lines of dash walk logic exist once.
- **Pre-pass counting.** `countSubSegments()` gives the exact quad count for buffer pre-allocation.

---

## Layer 2 (cont.): CPU Quad Expansion — Fix Buffer Sizing

### The problem

The Metal renderer pre-allocates buffer space using `vertexCount()` and `indexCount()`:

```gooey/src/platform/macos/metal/polyline_pipeline.zig#L200-206
        // Calculate total vertices and indices needed
        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;
        for (polylines) |pl| {
            total_vertices += pl.vertexCount();
            total_indices += pl.indexCount();
        }
```

These functions return `(point_count - 1) * 4` and `(point_count - 1) * 6` — the count for a solid line. A dashed line splits each segment into multiple sub-quads, so the actual count is higher. A 3-segment polyline with short dashes might produce 15 quads instead of 3. The Metal path would write past the allocated buffer.

The WebGPU path has an overflow guard and would silently truncate:

```gooey/src/platform/web/renderer.zig#L2156-2157
                // Skip if we'd overflow buffers
                if (vertex_offset + 4 > MAX_POLYLINE_VERTICES or index_offset + 6 > MAX_POLYLINE_INDICES) break;
```

### The fix: pre-pass count

Use the `DashIterator.countSubSegments()` function to get the exact quad count before writing anything. Update `vertexCount()` and `indexCount()` to account for dashes:

```/dev/null/vertex_count_fix.zig#L1-18
/// Calculate the number of vertices needed for GPU rendering.
/// For solid lines: each segment becomes a quad (4 vertices).
/// For dashed lines: pre-walk to count exact sub-segments.
pub fn vertexCount(self: Self) u32 {
    if (self.point_count < 2) return 0;
    if (self.dash_length == 0) {
        // Solid fast path — no iteration needed.
        return (self.point_count - 1) * 4;
    }
    // Dashed: exact count via pre-walk.
    const sub_count = DashIterator.countSubSegments(
        self.getPoints(),
        self.dash_length,
        self.gap_length,
        self.dash_offset,
    );
    return sub_count * 4;
}
```

Same pattern for `indexCount()` (`sub_count * 6`).

This is O(n) in point count — the same walk the renderer is about to do anyway. It gives exact counts, enables asserting against hard caps before writing anything, and fails fast if a degenerate dash pattern would blow the buffer.

### Expansion loop structure

```/dev/null/dashed_expansion.zig#L1-20
// If solid (dash_length == 0), use existing fast path unchanged.
if (pl.dash_length == 0) {
    // ... existing segment expansion (zero overhead for solid lines) ...
} else {
    var iter = DashIterator.init(
        points,
        pl.dash_length,
        pl.gap_length,
        pl.dash_offset,
    );
    while (iter.next()) |sub| {
        const dx = sub.p1.x - sub.p0.x;
        const dy = sub.p1.y - sub.p0.y;
        const len = @sqrt(dx * dx + dy * dy);
        // ... perpendicular math, emit quad (same as solid) ...
    }
}
```

---

## Layer 3: `DrawContext` API

### Avoiding method explosion

The existing API has `polyline()` and `polylineClipped()`. Adding `dashedPolyline()` and `dashedPolylineClipped()` is 4 methods, growing worse with future options. Use an options struct instead — prevents parameter mixups between `dash_length` and `gap_length` (two `f32`s that could be swapped), and keeps the API surface flat.

```/dev/null/draw_context_api.zig#L1-36
/// Draw a dashed polyline through multiple points.
///
/// ## Example
/// ```
/// ctx.dashedPolyline(&points, .{
///     .line_width = 2.0,
///     .dash_length = 8.0,
///     .gap_length = 4.0,
///     .color = Color.blue,
/// });
/// ```
pub fn dashedPolyline(self: *Self, points: []const [2]f32, options: struct {
    line_width: f32,
    dash_length: f32,
    gap_length: f32,
    dash_offset: f32 = 0,
    color: Color,
}) void {
    std.debug.assert(points.len >= 2);
    std.debug.assert(options.line_width > 0);
    std.debug.assert(options.dash_length > 0);
    std.debug.assert(options.gap_length > 0);

    if (points.len < 2) return;

    const scene_points = self.scene.allocator.alloc(Point, points.len) catch return;

    const ox = self.bounds.origin.x;
    const oy = self.bounds.origin.y;
    for (points, 0..) |p, i| {
        scene_points[i] = .{ .x = ox + p[0], .y = oy + p[1] };
    }

    const pl = Polyline.init(scene_points, options.line_width, Hsla.fromColor(options.color))
        .withDash(options.dash_length, options.gap_length)
        .withDashOffset(options.dash_offset);

    if (self.isOrdered()) {
        self.scene.insertPolylineWithOrder(pl, self.nextOrder(), self.clip_bounds) catch {};
    } else {
        self.scene.insertPolyline(pl) catch {};
    }
}
```

Clipping is handled by the existing clip stack and `isOrdered()` path — no separate `dashedPolylineClipped` variant needed.

---

## Float Drift in Long Polylines

For chart polylines with thousands of points, the cumulative `distance_along += seg_len` accumulates floating-point error. Over 5000 segments averaging 2px each, the value reaches ~10000.0 — still fine for f32 precision. For very long paths (scrolling time-series with 50K+ points), the error could become visible as dash phase drift.

Not a blocker for v1. If it ever matters, the fix is to periodically renormalize `distance_along` by `@mod(distance_along, period)` at segment boundaries — keeps the value small without changing the visual result. Add a comment noting this.

---

## Files Changed

| File | Change | Scope |
|------|--------|-------|
| `src/scene/polyline.zig` | Add `dash_length`, `gap_length`, `dash_offset` fields; `withDash()`, `withDashOffset()` builders; update comptime assertion 64→80; update `vertexCount()`/`indexCount()` for dashed lines; add `DashIterator` with `countSubSegments()` | Medium |
| `src/ui/canvas.zig` | Add `dashedPolyline()` with options struct | Small |
| `src/platform/macos/metal/polyline_pipeline.zig` | Branch on `dash_length`: solid uses existing fast path, dashed consumes `DashIterator` | Medium |
| `src/platform/web/renderer.zig` | Same `DashIterator` consumption in `renderPolylineBatch` | Medium |
| **No shader changes** | Metal `.metal` and WebGPU `.wgsl` are untouched | — |

## What Stays the Same

- Both GPU shaders — they render pre-expanded quads as before.
- `PolylineUniforms` structs (Metal and WebGPU) — dash info is consumed during CPU expansion, not passed to GPU.
- The batch iterator, scene insertion, and z-ordering.
- Solid polylines (`dash_length == 0`) — existing fast path, zero overhead.

---

## Checklist

- [ ] Add `dash_length`, `gap_length`, `dash_offset` fields to `Polyline` extern struct
- [ ] Update comptime size assertion from 64 to 80 bytes
- [ ] Add `withDash()` and `withDashOffset()` builder methods
- [ ] Implement `DashIterator` in `polyline.zig` with `next()` and `countSubSegments()`
- [ ] Update `vertexCount()` / `indexCount()` to use `countSubSegments()` for dashed lines
- [ ] Add unit tests for `DashIterator` (sub-segment positions, count accuracy, edge cases)
- [ ] Branch Metal quad expansion on `dash_length == 0` — solid fast path vs `DashIterator`
- [ ] Branch WebGPU quad expansion the same way
- [ ] Add `dashedPolyline()` with options struct to `DrawContext`
- [ ] Add comment about float drift for long polylines
- [ ] Update `polyline.zig` tests for new struct size and dash fields
