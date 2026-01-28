# Linux/Vulkan Path Rendering Implementation Plan

## Overview

This document outlines the implementation plan for bringing path, polyline, and point cloud rendering to the Linux/Vulkan backend, achieving feature parity with Mac/Metal and Web/WGPU.

---

## Current State

### What Linux/Vulkan Has ✅

| Feature                          | Status | File                         |
| -------------------------------- | ------ | ---------------------------- |
| Wayland surface creation         | ✅     | `wayland.zig`                |
| Vulkan swapchain                 | ✅     | `vk_renderer.zig`            |
| MSAA rendering                   | ✅     | `vk_renderer.zig`            |
| Unified pipeline (quads/shadows) | ✅     | `shaders/unified.vert/.frag` |
| Text/glyph rendering             | ✅     | `shaders/text.vert/.frag`    |
| SVG atlas rendering              | ✅     | `shaders/svg.vert/.frag`     |
| Image rendering                  | ✅     | `shaders/image.vert/.frag`   |

### What Linux/Vulkan is Missing ❌

| Feature                        | Status  | Reference Implementation                     |
| ------------------------------ | ------- | -------------------------------------------- |
| Path rendering (gradient)      | ❌ stub | `mac/metal/path_pipeline.zig`                |
| Path rendering (solid batched) | ❌ stub | `wgpu/shaders/path_solid.wgsl`               |
| Polyline rendering             | ❌ stub | `wgpu/shaders/polyline.wgsl`                 |
| Point cloud rendering          | ❌ stub | `wgpu/shaders/point_cloud.wgsl`              |
| Colored point cloud rendering  | ❌ stub | `mac/metal/colored_point_cloud_pipeline.zig` |

### Current Stub Code

```scene_renderer.zig#L193-210
.path => |paths| {
    // TODO: Implement path rendering for Linux
    if (DEBUG_BATCHES) {
        std.debug.print("PATH x{d} (stub - not rendered)\n", .{paths.len});
    }
},
.polyline => |polylines| {
    // TODO: Phase 4-5 - Implement polyline GPU pipeline
    if (DEBUG_BATCHES) {
        std.debug.print("POLYLINE x{d} (stub - not rendered)\n", .{polylines.len});
    }
},
.point_cloud => |point_clouds| {
    // TODO: Phase 4-5 - Implement point cloud GPU pipeline
    if (DEBUG_BATCHES) {
        std.debug.print("POINT_CLOUD x{d} (stub - not rendered)\n", .{point_clouds.len});
    }
},
.colored_point_cloud => |colored_clouds| {
    // TODO: Phase 6 - Implement colored point cloud GPU pipeline
    if (DEBUG_BATCHES) {
        std.debug.print("COLORED_POINT_CLOUD x{d} (stub - not rendered)\n", .{colored_clouds.len});
    }
},
```

---

## Architecture Overview

### Rendering Pipeline Flow

```
Scene → BatchIterator → scene_renderer.zig → vk_renderer.zig → Vulkan
                              ↓
                    drawPathBatch()
                    drawPolylineBatch()
                    drawPointCloudBatch()
                              ↓
                    path_pipeline (gradient)
                    solid_path_pipeline (batched)
                    polyline_pipeline
                    point_cloud_pipeline
```

### Data Flow

1. **PathInstance** (112 bytes) - per-instance transform, color, clip, gradient info
2. **PathVertex** (16 bytes) - mesh vertex (x, y, u, v)
3. **SolidPathVertex** (32 bytes) - baked transform + color for batching
4. **MeshPool** - shared vertex/index storage for triangulated paths

---

## Phase 0: Basic Path Rendering (Per-Instance)

**Goal:** Get path rendering working with individual draw calls per path.
**Effort:** 2-3 days

### 0a: Create GLSL Shaders

**File:** `src/platform/linux/shaders/path.vert`

```glsl
#version 450

// Vertex buffer (storage buffer for flexibility)
layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    vec4 vertices[];  // x, y, u, v packed
};

// Per-instance uniforms
layout(set = 0, binding = 1) uniform PathInstance {
    float offset_x;
    float offset_y;
    float scale_x;
    float scale_y;
    vec4 fill_color;      // HSLA
    vec4 clip_bounds;     // x, y, width, height
    uint gradient_type;   // 0=none, 1=linear, 2=radial
    uint gradient_stop_count;
    vec2 _pad;
    vec4 grad_params;     // linear: start.xy, end.xy / radial: center.xy, radius, inner
};

// Viewport uniforms
layout(set = 0, binding = 2) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_fill_color;
layout(location = 2) out vec4 out_clip_bounds;
layout(location = 3) out vec2 out_screen_pos;
layout(location = 4) flat out uint out_gradient_type;
layout(location = 5) out vec4 out_grad_params;

vec4 hsla_to_rgba(vec4 hsla) {
    float h = hsla.x;
    float s = hsla.y;
    float l = hsla.z;
    float a = hsla.w;

    float hue = h * 6.0;
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(hue, 2.0) - 1.0));
    float m = l - c / 2.0;

    vec3 rgb;
    if (hue < 1.0) rgb = vec3(c, x, 0.0);
    else if (hue < 2.0) rgb = vec3(x, c, 0.0);
    else if (hue < 3.0) rgb = vec3(0.0, c, x);
    else if (hue < 4.0) rgb = vec3(0.0, x, c);
    else if (hue < 5.0) rgb = vec3(x, 0.0, c);
    else rgb = vec3(c, 0.0, x);

    return vec4(rgb + m, a);
}

void main() {
    vec4 v = vertices[gl_VertexIndex];
    vec2 pos = vec2(v.x * scale_x + offset_x, v.y * scale_y + offset_y);
    vec2 viewport = vec2(viewport_width, viewport_height);
    vec2 ndc = pos / viewport * vec2(2.0, -2.0) + vec2(-1.0, 1.0);

    gl_Position = vec4(ndc, 0.0, 1.0);
    out_uv = v.zw;
    out_fill_color = hsla_to_rgba(fill_color);
    out_clip_bounds = clip_bounds;
    out_screen_pos = pos;
    out_gradient_type = gradient_type;
    out_grad_params = grad_params;
}
```

**File:** `src/platform/linux/shaders/path.frag`

```glsl
#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_fill_color;
layout(location = 2) in vec4 in_clip_bounds;
layout(location = 3) in vec2 in_screen_pos;
layout(location = 4) flat in uint in_gradient_type;
layout(location = 5) in vec4 in_grad_params;

layout(location = 0) out vec4 out_color;

// Gradient uniforms (for gradient paths)
layout(set = 0, binding = 3) uniform GradientUniforms {
    uint gradient_type;
    uint stop_count;
    vec2 _pad;
    vec4 param;
    vec4 stop_offsets[4];  // 16 stops packed into 4 vec4s
    vec4 stop_h[4];
    vec4 stop_s[4];
    vec4 stop_l[4];
    vec4 stop_a[4];
} gradient;

const float GRADIENT_RANGE_EPSILON = 0.0001;

float get_stop_offset(uint i) { return gradient.stop_offsets[i / 4u][i % 4u]; }
float get_stop_h(uint i) { return gradient.stop_h[i / 4u][i % 4u]; }
float get_stop_s(uint i) { return gradient.stop_s[i / 4u][i % 4u]; }
float get_stop_l(uint i) { return gradient.stop_l[i / 4u][i % 4u]; }
float get_stop_a(uint i) { return gradient.stop_a[i / 4u][i % 4u]; }

vec4 hsla_to_rgba(float h, float s, float l, float a) {
    float hue = h * 6.0;
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(hue, 2.0) - 1.0));
    float m = l - c / 2.0;

    vec3 rgb;
    if (hue < 1.0) rgb = vec3(c, x, 0.0);
    else if (hue < 2.0) rgb = vec3(x, c, 0.0);
    else if (hue < 3.0) rgb = vec3(0.0, c, x);
    else if (hue < 4.0) rgb = vec3(0.0, x, c);
    else if (hue < 5.0) rgb = vec3(x, 0.0, c);
    else rgb = vec3(c, 0.0, x);

    return vec4(rgb + m, a);
}

vec4 sample_gradient(float t_in) {
    float t = clamp(t_in, 0.0, 1.0);
    uint count = gradient.stop_count;
    if (count < 2u) return vec4(0.0, 0.0, 0.0, 1.0);

    uint i0 = 0u, i1 = 1u;
    for (uint i = 0u; i < count - 1u; i++) {
        if (t >= get_stop_offset(i) && t <= get_stop_offset(i + 1u)) {
            i0 = i;
            i1 = i + 1u;
            break;
        }
    }

    float offset0 = get_stop_offset(i0);
    float offset1 = get_stop_offset(i1);
    float range = offset1 - offset0;
    float factor = (range > GRADIENT_RANGE_EPSILON) ? (t - offset0) / range : 0.0;

    float h0 = get_stop_h(i0), h1 = get_stop_h(i1);
    if (abs(h1 - h0) > 0.5) {
        if (h0 < h1) h0 += 1.0;
        else h1 += 1.0;
    }

    float h = mod(h0 + (h1 - h0) * factor, 1.0);
    float s = mix(get_stop_s(i0), get_stop_s(i1), factor);
    float l = mix(get_stop_l(i0), get_stop_l(i1), factor);
    float a = mix(get_stop_a(i0), get_stop_a(i1), factor);

    return hsla_to_rgba(h, s, l, a);
}

void main() {
    // Clip test
    vec2 clip_min = in_clip_bounds.xy;
    vec2 clip_max = clip_min + in_clip_bounds.zw;
    if (in_screen_pos.x < clip_min.x || in_screen_pos.x > clip_max.x ||
        in_screen_pos.y < clip_min.y || in_screen_pos.y > clip_max.y) {
        discard;
    }

    vec4 color;

    if (in_gradient_type == 1u) {
        // Linear gradient
        vec2 start = in_grad_params.xy;
        vec2 end = in_grad_params.zw;
        vec2 dir = end - start;
        float len_sq = dot(dir, dir);
        float t = (len_sq < 0.0001) ? 0.0 : dot(in_uv - start, dir) / len_sq;
        color = sample_gradient(t);
    } else if (in_gradient_type == 2u) {
        // Radial gradient
        vec2 center = in_grad_params.xy;
        float radius = in_grad_params.z;
        float inner_radius = in_grad_params.w;
        float dist = length(in_uv - center);
        float t = (radius <= inner_radius) ? 1.0 : (dist - inner_radius) / (radius - inner_radius);
        color = sample_gradient(t);
    } else {
        color = in_fill_color;
    }

    if (color.a < 0.001) discard;

    // Premultiplied alpha output
    out_color = vec4(color.rgb * color.a, color.a);
}
```

### 0b: Compile Shaders to SPIR-V

**File:** `src/platform/linux/shaders/compile.sh` (update)

```bash
#!/bin/bash
# Add to existing compile script:

glslc path.vert -o path.vert.spv
glslc path.frag -o path.frag.spv
glslc path_solid.vert -o path_solid.vert.spv
glslc path_solid.frag -o path_solid.frag.spv
glslc polyline.vert -o polyline.vert.spv
glslc polyline.frag -o polyline.frag.spv
glslc point_cloud.vert -o point_cloud.vert.spv
glslc point_cloud.frag -o point_cloud.frag.spv
```

### 0c: Add Pipeline State to vk_renderer.zig

```zig
// Add to VulkanRenderer struct fields:
path_pipeline_layout: vk.PipelineLayout = null,
path_pipeline: vk.Pipeline = null,
path_descriptor_layout: vk.DescriptorSetLayout = null,
path_descriptor_set: vk.DescriptorSet = null,
path_vertex_buffer: vk.Buffer = null,
path_vertex_memory: vk.DeviceMemory = null,
path_index_buffer: vk.Buffer = null,
path_index_memory: vk.DeviceMemory = null,
path_instance_buffer: vk.Buffer = null,
path_instance_memory: vk.DeviceMemory = null,
path_gradient_buffer: vk.Buffer = null,
path_gradient_memory: vk.DeviceMemory = null,
```

### 0d: Create Pipeline (follow existing pattern)

```zig
fn createPathPipeline(self: *Self) !void {
    const vert_module = try self.createShaderModule(path_vert_spv);
    defer vk.vkDestroyShaderModule(self.device, vert_module, null);

    const frag_module = try self.createShaderModule(path_frag_spv);
    defer vk.vkDestroyShaderModule(self.device, frag_module, null);

    // ... follow pattern from createUnifiedPipeline() ...
    // Key differences:
    // - Uses storage buffer for vertices (binding 0)
    // - Uniform buffer for instance data (binding 1)
    // - Uniform buffer for viewport (binding 2)
    // - Uniform buffer for gradient (binding 3)
    // - Premultiplied alpha blending
}
```

### 0e: Integrate into scene_renderer.zig

```zig
.path => |paths| {
    if (pipelines.path_pipeline) |path_pipe| {
        drawPathBatch(cmd_buffer, paths, pipelines, mesh_pool, viewport_size);
    } else if (DEBUG_BATCHES) {
        std.debug.print("PATH x{d} (no pipeline)\n", .{paths.len});
    }
},
```

---

## Phase 1: Clip-Based Batching

**Goal:** Reduce draw calls by grouping consecutive paths with same clip bounds.
**Effort:** 1 day

Port the clip batching logic from `mac/metal/path_pipeline.zig`:

```zig
const MAX_CLIP_BATCHES = 64;

const ClipBatch = struct {
    clip: ClipBounds,
    start_index: u32,
    end_index: u32,

    pub fn count(self: ClipBatch) u32 {
        return self.end_index - self.start_index;
    }
};

// Group consecutive same-clip paths (preserves z-order)
fn groupByClip(instances: []const PathInstance) [MAX_CLIP_BATCHES]ClipBatch {
    // ... implementation ...
}
```

**Expected improvement:** 2-5x reduction in draw calls for typical UI

---

## Phase 2: Solid Path Fast Path

**Goal:** Single draw call per clip region for solid-color paths.
**Effort:** 2-3 days

### 2a: Create Solid Path Shaders

**File:** `src/platform/linux/shaders/path_solid.vert`

```glsl
#version 450

// Baked vertices (32 bytes each)
layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    // x, y (transformed), u, v, color_h, color_s, color_l, color_a
    vec4 vertices_pos[];   // x, y, u, v
    vec4 vertices_color[]; // h, s, l, a
};

layout(set = 0, binding = 1) uniform ClipBounds {
    vec4 clip;  // x, y, width, height
};

layout(set = 0, binding = 2) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

// ... vertex shader that reads pre-transformed vertices ...
```

### 2b: Add Solid Pipeline to vk_renderer.zig

```zig
solid_path_pipeline_layout: vk.PipelineLayout = null,
solid_path_pipeline: vk.Pipeline = null,
solid_path_vertex_buffer: vk.Buffer = null,
solid_path_vertex_memory: vk.DeviceMemory = null,
solid_path_index_buffer: vk.Buffer = null,
solid_path_index_memory: vk.DeviceMemory = null,
```

### 2c: Bake Transforms at Upload Time

```zig
fn bakeSolidPathVertices(
    instances: []const PathInstance,
    mesh_pool: *const MeshPool,
    out_vertices: []SolidPathVertex,
    out_indices: []u32,
) struct { vertex_count: u32, index_count: u32 } {
    var vertex_offset: u32 = 0;
    var index_offset: u32 = 0;

    for (instances) |inst| {
        const mesh = mesh_pool.getMesh(inst.getMeshRef());

        // Bake transform + color into vertices
        for (mesh.vertices) |v| {
            out_vertices[vertex_offset] = .{
                .x = v.x * inst.scale_x + inst.offset_x,
                .y = v.y * inst.scale_y + inst.offset_y,
                .u = v.u,
                .v = v.v,
                .color_h = inst.fill_h,
                .color_s = inst.fill_s,
                .color_l = inst.fill_l,
                .color_a = inst.fill_a,
            };
            vertex_offset += 1;
        }

        // Reindex
        for (mesh.indices) |idx| {
            out_indices[index_offset] = idx + vertex_offset - @intCast(mesh.vertices.len);
            index_offset += 1;
        }
    }

    return .{ .vertex_count = vertex_offset, .index_count = index_offset };
}
```

**Expected improvement:** 10-50x reduction for solid path batches

---

## Phase 3: Gradient/Solid Partitioning

**Goal:** Use optimized solid pipeline when possible, fall back to gradient pipeline.
**Effort:** 1 day

```zig
fn renderPathBatchOptimized(
    cmd_buffer: vk.CommandBuffer,
    paths: []const PathInstance,
    pipelines: Pipelines,
    mesh_pool: *const MeshPool,
    viewport_size: [2]f32,
) void {
    // Partition by gradient type
    var solid_paths: [MAX_PATHS]PathInstance = undefined;
    var gradient_paths: [MAX_PATHS]PathInstance = undefined;
    var solid_count: u32 = 0;
    var gradient_count: u32 = 0;

    for (paths) |path| {
        if (path.hasGradient()) {
            gradient_paths[gradient_count] = path;
            gradient_count += 1;
        } else {
            solid_paths[solid_count] = path;
            solid_count += 1;
        }
    }

    // Render solid paths with batched pipeline
    if (solid_count > 0) {
        renderSolidPathBatch(cmd_buffer, solid_paths[0..solid_count], ...);
    }

    // Render gradient paths individually
    if (gradient_count > 0) {
        renderGradientPaths(cmd_buffer, gradient_paths[0..gradient_count], ...);
    }
}
```

---

## Phase 4: Polyline Pipeline

**Goal:** Efficient rendering for chart line data.
**Effort:** 1-2 days

### 4a: Create Polyline Shaders

Port from `wgpu/shaders/polyline.wgsl`:

**File:** `src/platform/linux/shaders/polyline.vert`

```glsl
#version 450

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    vec2 vertices[];  // Already expanded to quads on CPU
};

layout(set = 0, binding = 1) uniform PolylineUniforms {
    vec4 color;       // HSLA
    vec4 clip_bounds; // x, y, width, height
};

layout(set = 0, binding = 2) uniform Uniforms {
    float viewport_width;
    float viewport_height;
};

// ... standard vertex transform ...
```

### 4b: CPU-Side Quad Expansion

```zig
fn expandPolylineToQuads(
    points: []const Point,
    line_width: f32,
    out_vertices: []GpuPolylineVertex,
    out_indices: []u32,
) struct { vertex_count: u32, index_count: u32 } {
    // Expand line segments to quads with proper miter joins
    // ... implementation from wgpu/web/renderer.zig ...
}
```

---

## Phase 5: Point Cloud Pipeline

**Goal:** Efficient rendering for scatter plots with SDF circles.
**Effort:** 1-2 days

### 5a: Create Point Cloud Shaders

Port from `wgpu/shaders/point_cloud.wgsl`:

**File:** `src/platform/linux/shaders/point_cloud.vert`

```glsl
#version 450

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    vec4 vertices[];  // x, y, u, v (quad corners)
};

layout(set = 0, binding = 1) uniform PointCloudUniforms {
    vec4 color;       // HSLA
    vec4 clip_bounds;
    float radius;
    vec3 _pad;
};

// ... vertex shader ...
```

**File:** `src/platform/linux/shaders/point_cloud.frag`

```glsl
#version 450

layout(location = 3) in vec2 in_uv;

// ... SDF circle with smoothstep anti-aliasing ...
float dist = length(in_uv);
float alpha = 1.0 - smoothstep(0.85, 1.0, dist);
```

---

## Phase 6: Colored Point Cloud Pipeline

**Goal:** Efficient rendering for scatter plots with per-point colors (single draw call for ALL points).
**Effort:** 1-2 days
**Reference:** `mac/metal/colored_point_cloud_pipeline.zig`

This is a critical optimization for the canvas drawing demo. Instead of 200 draw calls for 200 differently-colored dots, we render ALL points in a single GPU draw call by storing color per-vertex.

### 6a: Create Colored Point Cloud Shaders

**File:** `src/platform/linux/shaders/colored_point_cloud.vert`

```glsl
#version 450

// Per-vertex data (quad corner with UV for SDF + color)
layout(location = 0) in vec2 in_position;  // x, y
layout(location = 1) in vec2 in_uv;        // UV for SDF (-1 to 1)
layout(location = 2) in vec4 in_color;     // HSLA color per vertex

// Per-draw uniforms (color is per-vertex, not uniform)
layout(set = 0, binding = 0) uniform ColoredPointCloudUniforms {
    vec4 clip_bounds;  // x, y, width, height
    vec2 viewport_size;
    vec2 _pad;
};

layout(location = 0) out vec4 frag_color;
layout(location = 1) out vec4 frag_clip_bounds;
layout(location = 2) out vec2 frag_screen_pos;
layout(location = 3) out vec2 frag_uv;

// HSLA to RGBA conversion
vec4 hsla_to_rgba(vec4 hsla) {
    float h = hsla.x * 6.0;
    float s = hsla.y;
    float l = hsla.z;
    float a = hsla.w;
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(h, 2.0) - 1.0));
    float m = l - c / 2.0;
    vec3 rgb;
    if (h < 1.0) rgb = vec3(c, x, 0);
    else if (h < 2.0) rgb = vec3(x, c, 0);
    else if (h < 3.0) rgb = vec3(0, c, x);
    else if (h < 4.0) rgb = vec3(0, x, c);
    else if (h < 5.0) rgb = vec3(x, 0, c);
    else rgb = vec3(c, 0, x);
    return vec4(rgb + m, a);
}

void main() {
    // Convert to NDC
    vec2 ndc = in_position / viewport_size * vec2(2.0, -2.0) + vec2(-1.0, 1.0);

    gl_Position = vec4(ndc, 0.0, 1.0);
    frag_color = hsla_to_rgba(in_color);  // Color from vertex attribute
    frag_clip_bounds = clip_bounds;
    frag_screen_pos = in_position;
    frag_uv = in_uv;
}
```

**File:** `src/platform/linux/shaders/colored_point_cloud.frag`

```glsl
#version 450

layout(location = 0) in vec4 frag_color;
layout(location = 1) in vec4 frag_clip_bounds;
layout(location = 2) in vec2 frag_screen_pos;
layout(location = 3) in vec2 frag_uv;

layout(location = 0) out vec4 out_color;

void main() {
    // Clip test
    vec2 clip_min = frag_clip_bounds.xy;
    vec2 clip_max = clip_min + frag_clip_bounds.zw;
    if (frag_screen_pos.x < clip_min.x || frag_screen_pos.x > clip_max.x ||
        frag_screen_pos.y < clip_min.y || frag_screen_pos.y > clip_max.y) {
        discard;
    }

    // SDF circle: distance from center
    float dist = length(frag_uv);

    // Smooth anti-aliased edge
    float alpha = 1.0 - smoothstep(0.85, 1.0, dist);

    if (alpha < 0.001) discard;

    vec4 color = frag_color;
    color.a *= alpha;

    // Output premultiplied alpha
    out_color = vec4(color.rgb * color.a, color.a);
}
```

### 6b: Vertex Layout

```zig
/// Vertex for colored point quad (matches shader)
/// Includes per-vertex color for single-draw-call multi-color rendering
pub const ColoredPointVertex = extern struct {
    x: f32,          // position
    y: f32,
    u: f32,          // UV for SDF (-1 to 1)
    v: f32,
    color: [4]f32,   // HSLA color per vertex
};

// Size: 32 bytes per vertex
comptime {
    std.debug.assert(@sizeOf(ColoredPointVertex) == 32);
}
```

### 6c: Add Pipeline State to vk_renderer.zig

```zig
// Colored point cloud pipeline (Phase 6)
colored_point_cloud_pipeline_layout: vk.PipelineLayout,
colored_point_cloud_pipeline: vk.Pipeline,
colored_point_cloud_descriptor_layout: vk.DescriptorSetLayout,
colored_point_cloud_descriptor_set: vk.DescriptorSet,
colored_point_cloud_vertex_buffer: vk.Buffer,
colored_point_cloud_vertex_memory: vk.DeviceMemory,
colored_point_cloud_index_buffer: vk.Buffer,
colored_point_cloud_index_memory: vk.DeviceMemory,
```

### 6d: Integrate into scene_renderer.zig

```zig
.colored_point_cloud => |colored_clouds| {
    for (colored_clouds) |cloud| {
        drawColoredPointCloud(cmd_buffer, cloud);
    }
},

fn drawColoredPointCloud(cmd_buffer: vk.CommandBuffer, cloud: *const ColoredPointCloud) void {
    // Build vertex data: 4 vertices per point (quad corners)
    // Each vertex includes position, UV, and HSLA color
    const point_count = cloud.count;
    const vertex_count = point_count * 4;
    const index_count = point_count * 6;

    // Upload vertices with per-point colors baked in
    // Single vkCmdDrawIndexed for ALL points
}
```

### 6e: Performance Impact

| Scenario                          | Before (fillCircle per dot)   | After (coloredPointCloud)    |
| --------------------------------- | ----------------------------- | ---------------------------- |
| 200 dots, 200 colors              | 200 draw calls, ~12,800 verts | **1 draw call**, 800 verts   |
| 500 dots, 500 colors              | 500 draw calls, ~32,000 verts | **1 draw call**, 2,000 verts |
| Canvas demo (interactive drawing) | Stutters at ~100 dots         | Smooth at 512+ dots          |

---

## Summary: Files to Create/Modify

| Phase | File                                     | Changes                                                |
| ----- | ---------------------------------------- | ------------------------------------------------------ |
| 0     | `linux/shaders/path.vert`                | **NEW** - gradient path vertex shader                  |
| 0     | `linux/shaders/path.frag`                | **NEW** - gradient path fragment shader                |
| 0     | `linux/vk_renderer.zig`                  | Add path pipeline, buffers, descriptors                |
| 0     | `linux/scene_renderer.zig`               | Replace stub with `drawPathBatch()`                    |
| 1     | `linux/scene_renderer.zig`               | Add clip-based batch grouping                          |
| 2     | `linux/shaders/path_solid.vert`          | **NEW** - solid path vertex shader                     |
| 2     | `linux/shaders/path_solid.frag`          | **NEW** - solid path fragment shader                   |
| 2     | `linux/vk_renderer.zig`                  | Add solid path pipeline                                |
| 2     | `linux/scene_renderer.zig`               | Add `renderSolidPathBatch()`                           |
| 3     | `linux/scene_renderer.zig`               | Add `renderPathBatchOptimized()`                       |
| 4     | `linux/shaders/polyline.vert`            | **NEW** - polyline vertex shader                       |
| 4     | `linux/shaders/polyline.frag`            | **NEW** - polyline fragment shader                     |
| 4     | `linux/vk_renderer.zig`                  | Add polyline pipeline                                  |
| 4     | `linux/scene_renderer.zig`               | Replace polyline stub                                  |
| 5     | `linux/shaders/point_cloud.vert`         | **NEW** - point cloud vertex shader                    |
| 5     | `linux/shaders/point_cloud.frag`         | **NEW** - point cloud fragment shader                  |
| 5     | `linux/vk_renderer.zig`                  | Add point cloud pipeline                               |
| 5     | `linux/scene_renderer.zig`               | Replace point cloud stub                               |
| 6     | `linux/shaders/colored_point_cloud.vert` | **NEW** - per-vertex color point cloud vertex shader   |
| 6     | `linux/shaders/colored_point_cloud.frag` | **NEW** - per-vertex color point cloud fragment shader |
| 6     | `linux/vk_renderer.zig`                  | Add colored point cloud pipeline                       |
| 6     | `linux/scene_renderer.zig`               | Replace colored point cloud stub                       |
| All   | `linux/shaders/compile.sh`               | Add new shader compilation commands                    |

---

## Memory Budget (per CLAUDE.md)

```zig
// Static allocation limits
const MAX_PATH_VERTICES: u32 = 65536;
const MAX_PATH_INDICES: u32 = 131072;
const MAX_SOLID_BATCH_VERTICES: u32 = 32768;
const MAX_SOLID_BATCH_INDICES: u32 = 65536;
const MAX_POLYLINE_VERTICES: u32 = 16384;
const MAX_POLYLINE_INDICES: u32 = 24576;
const MAX_POINT_CLOUD_VERTICES: u32 = 16384;
const MAX_POINT_CLOUD_INDICES: u32 = 24576;
const MAX_COLORED_POINT_CLOUD_VERTICES: u32 = 16384;  // 4 verts per point = ~4000 points
const MAX_COLORED_POINT_CLOUD_INDICES: u32 = 24576;   // 6 indices per point
const MAX_CLIP_BATCHES: u32 = 64;
const MAX_PATHS_PER_FRAME: u32 = 4096;
```

---

## Expected Results

| Scenario                           | Before       | After                                                  |
| ---------------------------------- | ------------ | ------------------------------------------------------ |
| 200 solid paths, 1 clip region     | Not rendered | **1 draw call**                                        |
| 200 solid paths, 5 clip regions    | Not rendered | **5 draw calls**                                       |
| 100 solid + 100 gradient, 1 clip   | Not rendered | **1 + 100 = 101 draw calls**                           |
| 1000-point polyline                | Not rendered | **1 draw call**                                        |
| 500-point scatter plot (uniform)   | Not rendered | **1 draw call**                                        |
| 500-point scatter plot (colored)   | Not rendered | **1 draw call** (per-vertex colors)                    |
| Canvas demo (200 dots, 200 colors) | Not rendered | **1 draw call** (was 200 on Metal before optimization) |

---

## Implementation Order

| Phase | Effort   | Description                    | Dependencies |
| ----- | -------- | ------------------------------ | ------------ |
| 0     | 2-3 days | Basic path rendering           | None         |
| 1     | 0.5 days | Clip-based batching            | Phase 0      |
| 2     | 1-2 days | Solid path fast path           | Phase 0      |
| 3     | 0.5 days | Gradient/solid partitioning    | Phase 2      |
| 4     | 1-2 days | Polyline pipeline              | None         |
| 5     | 1-2 days | Point cloud pipeline (uniform) | None         |
| 6     | 1-2 days | Colored point cloud pipeline   | None         |

**Note:** Phase 6 (Colored Point Cloud) is critical for the `canvas_drawing.zig` example which uses `pointCloudColoredArrays()` to render hundreds of differently-colored dots in a single draw call.
