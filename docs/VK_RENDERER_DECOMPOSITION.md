# Vulkan Renderer Decomposition & Optimization Proposal

## The Problem

`vk_renderer.zig` at **4,179 lines** violates the 70-line function limit from CLAUDE.md and concentrates 8 distinct responsibilities into one file. For comparison, the Metal backend spreads similar functionality across **18 focused files** under `src/platform/macos/metal/`, with `renderer.zig` acting as a ~280-line thin coordinator that delegates to `pipelines.zig`, `render_pass.zig`, `text.zig`, `svg_pipeline.zig`, `image_pipeline.zig`, etc.

The Vulkan backend should follow this same pattern.

---

## Current Anatomy

Every function in the file mapped to a logical domain:

| Domain                     | Lines                                                      | Functions                                                      | Notes                                      |
| -------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------ |
| GPU Types & Constants      | L1–212                                                     | 3 structs + `fromScene` helpers                                | Self-contained, no Vulkan state dependency |
| Instance/Device/Debug      | L921–1185                                                  | 8 functions                                                    | One-time setup, rarely touched             |
| Swapchain + MSAA           | L828–919, L1187–1350, L2751–2924                           | 6 functions                                                    | Resize-hot path, coupled together          |
| Render Pass & Framebuffers | L1352–1542                                                 | 3 functions                                                    | Depends on swapchain output                |
| Command Buffers & Sync     | L1544–1616                                                 | 4 functions                                                    | Infrastructure                             |
| Buffers                    | L552–718, L1618–1718                                       | 6 functions                                                    | Generic `createBuffer` + typed buffers     |
| Descriptors                | L1720–1971, L2001–2054, L3201–3281, L3558–3638, L3915–3995 | 9 functions                                                    | Layouts, pools, sets, per-atlas updates    |
| **Pipelines**              | L2056–2722                                                 | **5 functions, ~660 lines**                                    | **~90% copy-paste across 4 pipelines**     |
| **Atlas Upload**           | L2927–3995                                                 | **9 functions, ~1,070 lines**                                  | **~95% copy-paste across 3 atlas types**   |
| Coordinator                | L370–825, L2726–2748, L3998–4179                           | `init`, `deinit`, `initWithWaylandSurface`, `resize`, `render` | Wiring                                     |

The **pipelines** and **atlas upload** sections are the biggest offenders — nearly 1,730 lines of near-identical boilerplate.

---

## Verified Duplication Analysis

### Pipelines: 4 functions, 3 parameters of variation, 644 lines of copy-paste

The four `create*Pipeline` functions (L2056–2705) are structurally identical across ~161 lines each. A code-level diff reveals exactly three differences:

| Function                | Shader SPV  | Descriptor Layout           | `srcColorBlendFactor` |
| ----------------------- | ----------- | --------------------------- | --------------------- |
| `createUnifiedPipeline` | `unified_*` | `unified_descriptor_layout` | `SRC_ALPHA`           |
| `createTextPipeline`    | `text_*`    | `text_descriptor_layout`    | `SRC_ALPHA`           |
| `createSvgPipeline`     | `svg_*`     | `svg_descriptor_layout`     | `ONE` (premultiplied) |
| `createImagePipeline`   | `image_*`   | `image_descriptor_layout`   | `SRC_ALPHA`           |

Everything else — vertex input, input assembly, viewport state, rasterizer, multisampling, dynamic state, pipeline layout creation, pipeline creation — is character-for-character identical.

**Note:** `createTextPipeline` has a misleading comment at L2318 that says "Text uses premultiplied alpha blending" but the actual blend factor is `VK_BLEND_FACTOR_SRC_ALPHA` (standard blending). Only SVG at L2486 truly uses `VK_BLEND_FACTOR_ONE` (premultiplied). This comment should be corrected during extraction.

### Atlas Upload: 3 × 3 functions, 2 parameters of variation, ~1,070 lines of copy-paste

Three groups of three functions each (`upload*Atlas` + `upload*AtlasData` + `update*DescriptorSet`) repeat with only two differences:

| Atlas | VkFormat         | Bytes/Pixel | Target Fields                                           |
| ----- | ---------------- | ----------- | ------------------------------------------------------- |
| Text  | `R8_UNORM`       | 1           | `atlas_image/memory/view/width/height/generation`       |
| SVG   | `R8G8B8A8_UNORM` | 4           | `svg_atlas_image/memory/view/width/height/generation`   |
| Image | `R8G8B8A8_UNORM` | 4           | `image_atlas_image/memory/view/width/height/generation` |

The `upload*AtlasData` functions (~163 lines each) have identical command buffer recording: reset, begin, barrier to transfer dst, copy buffer to image, barrier to shader read, end, submit, wait. The only variable is which `self.*_image` field is referenced and the bytes-per-pixel multiplier.

### Descriptor Layouts: 3 identical layouts, acknowledged in comments

The code already documents the duplication:

- L1810: `// SVG pipeline: storage buffer + uniform buffer + texture + sampler (same layout as text)`
- L1849: `// Image pipeline: storage buffer + uniform buffer + texture + sampler (same layout as SVG/text)`

The binding arrays for text (L1759–1793), SVG (L1811–1845), and image (L1850–1884) are byte-for-byte identical: storage buffer at binding 0 (vertex stage), uniform buffer at binding 1 (vertex stage), sampled image at binding 2 (fragment stage), sampler at binding 3 (fragment stage).

### Descriptor Set Updates: 3 identical functions

`updateTextDescriptorSet` (L3201–3281), `updateSvgDescriptorSet` (L3558–3638), and `updateImageDescriptorSet` (L3915–3995) are identical except for which buffer/image view/descriptor set they reference.

### recreateSwapchain duplicates createFramebuffers

`recreateSwapchain` (L2887–2924) contains an inline copy of framebuffer creation logic that already exists in `createFramebuffers` (L1496–1542).

---

## Proposed File Structure

```
src/platform/linux/
├── vk_renderer.zig        # Coordinator struct + public API (~350 lines)
├── vk_types.zig           # GPU types, constants (~210 lines)
├── vk_instance.zig        # Instance, device, debug messenger (~280 lines)
├── vk_swapchain.zig       # Swapchain, MSAA, render pass, framebuffers (~400 lines)
├── vk_buffers.zig         # Buffer creation, commands, sync objects (~250 lines)
├── vk_descriptors.zig     # Descriptor layouts, pool, sets, updates (~300 lines)
├── vk_pipelines.zig       # Pipeline creation via generic helper (~200 lines)
├── vk_atlas.zig           # Atlas upload via generic helper (~250 lines)
├── vulkan.zig             # (existing) C API bindings
├── scene_renderer.zig     # (existing) Batch drawing
└── shaders/               # (existing) SPIR-V
```

**Total: ~2,240 lines** (down from 4,179). A **46% reduction** from deduplication alone, before factoring in readability gains.

---

## Module Designs

### 1. `vk_types.zig` — Pure data, zero Vulkan state

```zig
//! GPU types for Vulkan shader communication
pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 2048;
pub const MAX_IMAGES: u32 = 1024;
pub const MAX_FRAMES_IN_FLIGHT: u32 = 2;
pub const MAX_SURFACE_FORMATS: u32 = 128;
pub const MAX_PRESENT_MODES: u32 = 16;

pub const Uniforms = extern struct { ... };
pub const GpuGlyph = extern struct { ... };
pub const GpuSvg = extern struct { ... };
pub const GpuImage = extern struct { ... };
```

Already imported by `scene_renderer.zig` (L24–26) — this decouples the types from the renderer struct.

### 2. `vk_instance.zig` — Free functions with targeted parameters

```zig
//! Vulkan instance, device, and debug messenger creation
pub fn createInstance(instance: *vk.Instance, debug_messenger: *vk.DebugUtilsMessengerEXT) !void { ... }
pub fn destroyDebugMessenger(instance: vk.Instance, messenger: vk.DebugUtilsMessengerEXT) void { ... }
pub fn createWaylandSurface(instance: vk.Instance, wl_display: *anyopaque, wl_surface: *anyopaque, surface: *vk.Surface) !void { ... }
pub fn pickPhysicalDevice(instance: vk.Instance, surface: vk.Surface) !PhysicalDeviceResult { ... }
pub fn createLogicalDevice(physical_device: vk.PhysicalDevice, families: QueueFamilies) !DeviceResult { ... }
```

Each function takes only what it needs — not the entire `*VulkanRenderer`. Follows the "shrink scope aggressively" principle from CLAUDE.md.

### 3. `vk_swapchain.zig` — Swapchain lifecycle, MSAA, render pass, framebuffers

All coupled to swapchain extent/format:

```zig
//! Swapchain management, MSAA, render pass, and framebuffers
pub fn createSwapchain(device: vk.Device, physical_device: vk.PhysicalDevice, surface: vk.Surface, width: u32, height: u32, old_swapchain: ?vk.Swapchain) !SwapchainResult { ... }
pub fn createMSAAResources(device: vk.Device, format: c_uint, extent: vk.Extent2D, sample_count: c_uint, mem_props: *const vk.PhysicalDeviceMemoryProperties) !MSAAResult { ... }
pub fn createRenderPass(device: vk.Device, format: c_uint, sample_count: c_uint) !vk.RenderPass { ... }
pub fn createFramebuffers(device: vk.Device, render_pass: vk.RenderPass, image_views: []const vk.ImageView, msaa_view: ?vk.ImageView, extent: vk.Extent2D, sample_count: c_uint) !void { ... }
pub fn getMaxUsableSampleCount(physical_device: vk.PhysicalDevice) c_uint { ... }
```

`recreateSwapchain` in the coordinator calls `createFramebuffers` instead of inlining a copy.

### 4. `vk_pipelines.zig` — Generic pipeline creation

```zig
//! Vulkan graphics pipeline creation

pub const BlendMode = enum {
    standard,       // srcAlpha / oneMinusSrcAlpha (unified, text, image)
    premultiplied,  // one / oneMinusSrcAlpha (SVG only)
};

pub const PipelineConfig = struct {
    vert_spv: []align(4) const u8,
    frag_spv: []align(4) const u8,
    descriptor_layout: vk.DescriptorSetLayout,
    blend_mode: BlendMode = .standard,
};

pub const PipelineResult = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
};

/// Create a graphics pipeline. One function replaces four copy-pasted functions.
pub fn createGraphicsPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    sample_count: c_uint,
    config: PipelineConfig,
) !PipelineResult {
    const vert_module = try createShaderModule(device, config.vert_spv);
    defer vk.vkDestroyShaderModule(device, vert_module, null);
    const frag_module = try createShaderModule(device, config.frag_spv);
    defer vk.vkDestroyShaderModule(device, frag_module, null);

    // ... shared pipeline state setup (vertex input, rasterizer, multisampling, dynamic state)

    const color_blend_attachment = switch (config.blend_mode) {
        .standard => standardBlendAttachment(),
        .premultiplied => premultipliedBlendAttachment(),
    };

    // ... create layout + pipeline, return both
}

fn createShaderModule(device: vk.Device, spv: []align(4) const u8) !vk.ShaderModule { ... }
fn standardBlendAttachment() vk.PipelineColorBlendAttachmentState { ... }
fn premultipliedBlendAttachment() vk.PipelineColorBlendAttachmentState { ... }
```

Coordinator usage:

```zig
const unified = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
    .vert_spv = unified_vert_spv,
    .frag_spv = unified_frag_spv,
    .descriptor_layout = self.unified_descriptor_layout,
});
self.unified_pipeline = unified.pipeline;
self.unified_pipeline_layout = unified.layout;

const svg = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
    .vert_spv = svg_vert_spv,
    .frag_spv = svg_frag_spv,
    .descriptor_layout = self.svg_descriptor_layout,
    .blend_mode = .premultiplied,
});
self.svg_pipeline = svg.pipeline;
self.svg_pipeline_layout = svg.layout;
```

**Impact: 660 → ~160 lines. Removes ~500 lines of copy-paste.**

### 5. `vk_atlas.zig` — Generic atlas upload

```zig
//! Atlas texture upload for text, SVG, and image atlases

pub const AtlasFormat = enum {
    r8,    // Text atlas: 1 byte per pixel
    rgba8, // SVG/Image atlas: 4 bytes per pixel

    pub fn vkFormat(self: AtlasFormat) c_uint {
        return switch (self) {
            .r8 => vk.VK_FORMAT_R8_UNORM,
            .rgba8 => vk.VK_FORMAT_R8G8B8A8_UNORM,
        };
    }

    pub fn bytesPerPixel(self: AtlasFormat) u32 {
        return switch (self) {
            .r8 => 1,
            .rgba8 => 4,
        };
    }
};

/// Holds all Vulkan resources for a single atlas texture.
/// Replaces 7 individual fields per atlas (21 fields total → 3 structs).
pub const AtlasResources = struct {
    image: ?vk.Image = null,
    memory: ?vk.DeviceMemory = null,
    view: ?vk.ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 0,

    pub fn destroy(self: *AtlasResources, device: vk.Device) void {
        if (self.view) |v| vk.vkDestroyImageView(device, v, null);
        if (self.image) |i| vk.vkDestroyImage(device, i, null);
        if (self.memory) |m| vk.vkFreeMemory(device, m, null);
        self.* = .{};
    }
};

/// Shared transfer state — avoids passing 5 individual sync fields.
pub const TransferContext = struct {
    staging_buffer: *?vk.Buffer,
    staging_memory: *?vk.DeviceMemory,
    staging_mapped: *?*anyopaque,
    staging_size: *vk.DeviceSize,
    transfer_command_buffer: vk.CommandBuffer,
    transfer_fence: vk.Fence,
    graphics_queue: vk.Queue,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    device: vk.Device,
    create_buffer_fn: *const fn (...) !void,  // or pass device + mem_properties and inline
};

/// Upload atlas data — one function handles text, SVG, and image atlases.
pub fn uploadAtlas(
    device: vk.Device,
    resources: *AtlasResources,
    data: []const u8,
    width: u32,
    height: u32,
    format: AtlasFormat,
    transfer: *TransferContext,
) !void {
    std.debug.assert(width > 0 and height > 0);
    std.debug.assert(data.len == width * height * format.bytesPerPixel());
    // ... single implementation of create-image + staging-upload + barrier + copy + transition
}
```

This also simplifies the `VulkanRenderer` struct: 21 individual atlas fields collapse to 3 `AtlasResources` structs.

**Impact: 1,070 → ~250 lines. Removes ~820 lines of copy-paste.**

### 6. `vk_descriptors.zig` — Layouts, pool, sets, updates

```zig
//! Descriptor layout, pool, set creation and updates

/// Only two layouts needed: unified (storage + uniform) and textured (storage + uniform + image + sampler).
/// Text, SVG, and image pipelines all share the textured layout.
pub fn createUnifiedLayout(device: vk.Device) !vk.DescriptorSetLayout { ... }
pub fn createTexturedLayout(device: vk.Device) !vk.DescriptorSetLayout { ... }

pub fn createDescriptorPool(device: vk.Device) !vk.DescriptorPool { ... }

pub fn allocateDescriptorSets(
    device: vk.Device,
    pool: vk.DescriptorPool,
    unified_layout: vk.DescriptorSetLayout,
    textured_layout: vk.DescriptorSetLayout,
) !DescriptorSetsResult { ... }

/// Generic descriptor set update — replaces updateTextDescriptorSet, updateSvgDescriptorSet,
/// updateImageDescriptorSet (three identical ~80-line functions).
pub fn updateAtlasDescriptorSet(
    device: vk.Device,
    descriptor_set: vk.DescriptorSet,
    storage_buffer: vk.Buffer,
    storage_range: vk.DeviceSize,
    uniform_buffer: vk.Buffer,
    atlas_view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    // Single implementation of the 4-write pattern
}
```

**Impact: ~240 → ~40 lines for descriptor updates. ~167 → ~50 lines for layouts. 2 fewer Vulkan objects.**

---

## Migration Strategy

This can be done incrementally without breaking anything. Each phase is a single commit.

### Phase 1 — Extract `vk_types.zig` (zero risk)

Pure data move. No Vulkan state involved.

- Move `Uniforms`, `GpuGlyph`, `GpuSvg`, `GpuImage`, and all `MAX_*` constants
- Update `scene_renderer.zig` imports (L24–26 currently import from `vk_renderer.zig`)
- `vk_renderer.zig` re-exports or updates internal references

### Phase 2 — Extract `vk_pipelines.zig` (biggest bang for buck)

- Write the generic `createGraphicsPipeline` function
- Replace 4 methods with 4 calls in the coordinator
- Fix the misleading "premultiplied" comment on `createTextPipeline` (L2318) — text uses standard `SRC_ALPHA` blending
- Delete `createUnifiedPipeline`, `createTextPipeline`, `createSvgPipeline`, `createImagePipeline`, `createShaderModule`
- Delete `destroyUnifiedPipeline`, `destroyTextPipeline`, `destroySvgPipeline`, `destroyImagePipeline` (replace with generic destroy taking pipeline + layout)

### Phase 3 — Extract `vk_atlas.zig` (second biggest win)

- Introduce `AtlasResources` struct, replace 21 individual fields with 3 struct instances
- Write generic `uploadAtlas` + `uploadAtlasData`
- Replace 6 upload methods with parameterized calls
- Wire `TransferContext` from coordinator fields

### Phase 4 — Extract `vk_instance.zig`, `vk_swapchain.zig`, `vk_buffers.zig`, `vk_descriptors.zig`

Straightforward extractions, one at a time. Each is a separate commit.

- `vk_instance.zig`: Move `createInstance`, `debugCallback`, `createDebugMessenger`, `destroyDebugMessenger`, `createWaylandSurface`, `pickPhysicalDevice`, `isDeviceSuitable`, `createLogicalDevice`
- `vk_swapchain.zig`: Move `createSwapchain`, `createMSAAResources`, `createRenderPass`, `createFramebuffers`, `getMaxUsableSampleCount`, and refactor `recreateSwapchain` to call `createFramebuffers` instead of inlining a copy
- `vk_buffers.zig`: Move `createBuffer`, `createBuffers`, `destroyBuffer`, `createCommandPool`, `allocateCommandBuffers`, `createSyncObjects`
- `vk_descriptors.zig`: Move all descriptor layout/pool/set logic

### Phase 5 — Merge identical descriptor layouts

Collapse 3 identical textured layouts into 1 shared layout.

**⚠️ `deinit` trap:** Currently `destroyDescriptorLayouts` (L657–666) destroys all four layouts independently. When text/SVG/image all point to the same handle, this becomes a triple-free. Two safe approaches:

**Option A — Dedicated field, aliases removed:**

```zig
// Struct fields:
unified_descriptor_layout: vk.DescriptorSetLayout,
textured_descriptor_layout: vk.DescriptorSetLayout,  // shared by text, SVG, image

// Deinit:
vk.vkDestroyDescriptorSetLayout(self.device, self.unified_descriptor_layout, null);
vk.vkDestroyDescriptorSetLayout(self.device, self.textured_descriptor_layout, null);
```

**Option B — Keep aliases, guard destroy with assertion:**

```zig
// Deinit:
std.debug.assert(self.text_descriptor_layout == self.svg_descriptor_layout);
std.debug.assert(self.svg_descriptor_layout == self.image_descriptor_layout);
vk.vkDestroyDescriptorSetLayout(self.device, self.unified_descriptor_layout, null);
vk.vkDestroyDescriptorSetLayout(self.device, self.text_descriptor_layout, null);
```

Option A is cleaner. The aliases just add confusion.

---

## Summary

| Metric                         | Before                  | After                      |
| ------------------------------ | ----------------------- | -------------------------- |
| Total lines                    | 4,179                   | ~2,240                     |
| Largest file                   | 4,179 (vk_renderer.zig) | ~400 (coordinator)         |
| Copy-pasted pipeline code      | 660 lines (4×)          | ~160 lines (1× generic)    |
| Copy-pasted atlas code         | 1,070 lines (3×)        | ~250 lines (1× generic)    |
| Copy-pasted descriptor updates | 240 lines (3×)          | ~40 lines (1× generic)     |
| Descriptor layouts             | 4 (3 identical)         | 2                          |
| VulkanRenderer atlas fields    | 21 individual fields    | 3 `AtlasResources` structs |
| Files                          | 1                       | 8                          |

The deduplication in pipelines, atlas upload, and descriptor updates accounts for **~1,520 fewer lines** — that's the real win, not just the file split.

---

# Runtime Performance Improvements

The decomposition above addresses **code organization**. This section addresses **frame-time performance** — changes that make the renderer faster at runtime, independent of how the code is split across files.

## Priority Matrix

| Priority    | Issue                                                | Impact                                            |
| ----------- | ---------------------------------------------------- | ------------------------------------------------- |
| 🔴 Critical | Triple-buffer storage buffers + descriptors          | Enables CPU-GPU parallelism (Metal parity)        |
| 🔴 Critical | Batch atlas uploads into single submission           | Eliminates ~2 GPU round-trips per atlas update    |
| 🟡 Medium   | Pre-allocate staging buffer at init                  | Zero mid-frame allocations (CLAUDE.md compliance) |
| 🟡 Medium   | Replace `vkDeviceWaitIdle` with targeted fence waits | Smoother window resize                            |
| 🟡 Medium   | Sub-allocate memory from pools                       | Fewer kernel calls, better driver compat          |
| 🟢 Low      | Deduplicate descriptor layouts (3 → 1)               | Fewer Vulkan objects, no triple-free bug          |
| 🟢 Low      | `recreateSwapchain` calls `createFramebuffers`       | Eliminates divergent code path                    |

---

## 1. Triple-Buffered Per-Frame Resources (Metal Parity)

### The Problem

The Metal backend triple-buffers **every pipeline's instance data** (`FRAME_COUNT = 3`):

- `text.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `svg_pipeline.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `image_pipeline.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `polyline_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`
- `point_cloud_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`
- `colored_point_cloud_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`

Each pipeline rotates via `nextFrame()` at the start of each frame, so the CPU writes to buffer N while the GPU reads from buffer N-1 and N-2. No contention, no stalls.

The Vulkan backend has `MAX_FRAMES_IN_FLIGHT = 2` but only **one** set of storage buffers shared across all frames:

```zig
// Current: single-buffered — CPU and GPU fight over the same memory
primitive_buffer: vk.Buffer = null,
glyph_buffer: vk.Buffer = null,
svg_buffer: vk.Buffer = null,
image_buffer: vk.Buffer = null,
uniform_buffer: vk.Buffer = null,
```

This forces the fence wait at the top of `render()` to be **blocking** — the CPU cannot start writing frame N+1's data until the GPU finishes reading frame N's data from the same buffer.

```
Current timeline (serialized):
CPU: [wait fence]---[write buffers + record]---[submit]---[wait fence]---...
GPU:               [idle]                      [render]                 [idle]
```

### The Fix

Introduce a `FrameResources` struct and triple-buffer it:

```zig
const FRAME_COUNT = 3;

const FrameResources = struct {
    // Storage buffers (one per pipeline type)
    primitive_buffer: vk.Buffer = null,
    primitive_memory: vk.DeviceMemory = null,
    primitive_mapped: ?*anyopaque = null,

    glyph_buffer: vk.Buffer = null,
    glyph_memory: vk.DeviceMemory = null,
    glyph_mapped: ?*anyopaque = null,

    svg_buffer: vk.Buffer = null,
    svg_memory: vk.DeviceMemory = null,
    svg_mapped: ?*anyopaque = null,

    image_buffer: vk.Buffer = null,
    image_memory: vk.DeviceMemory = null,
    image_mapped: ?*anyopaque = null,

    uniform_buffer: vk.Buffer = null,
    uniform_memory: vk.DeviceMemory = null,
    uniform_mapped: ?*anyopaque = null,

    // Per-frame descriptor sets (reference this frame's buffers)
    unified_descriptor_set: vk.DescriptorSet = null,
    text_descriptor_set: vk.DescriptorSet = null,
    svg_descriptor_set: vk.DescriptorSet = null,
    image_descriptor_set: vk.DescriptorSet = null,

    // Per-frame sync
    fence: vk.Fence = null,
    image_available_semaphore: vk.Semaphore = null,
    render_finished_semaphore: vk.Semaphore = null,

    // Per-frame command buffer
    command_buffer: vk.CommandBuffer = null,
};
```

The renderer struct becomes:

```zig
frames: [FRAME_COUNT]FrameResources = [_]FrameResources{.{}} ** FRAME_COUNT,
current_frame: u32 = 0,
```

And `render()` uses per-frame resources:

```zig
pub fn render(self: *Self, scene: *const Scene) void {
    const frame = &self.frames[self.current_frame];

    // Wait only for THIS frame's fence — the other two frames are free
    _ = vk.vkWaitForFences(self.device, 1, &frame.fence, vk.TRUE, maxInt);
    _ = vk.vkResetFences(self.device, 1, &frame.fence);

    // CPU writes to frame.primitive_mapped, frame.glyph_mapped, etc.
    // GPU may still be reading from frames[(current + 1) % 3] — no conflict
    ...

    self.current_frame = (self.current_frame + 1) % FRAME_COUNT;
}
```

```
Triple-buffered timeline (overlapped):
CPU: [write buf 0 + record]---[write buf 1 + record]---[write buf 2 + record]---...
GPU:                          [render 0]                [render 1]                ...
```

### Descriptor Pool Sizing

Triple-buffering descriptor sets means 3× the descriptor set allocations. The pool must be sized accordingly:

```zig
// Before: 4 sets (unified + text + svg + image)
// After: 4 × FRAME_COUNT = 12 sets
const pool_size = 4 * FRAME_COUNT;
```

Each frame's descriptor sets point to that frame's buffers. Atlas image views and samplers are shared (they don't change per-frame).

### Why Triple and Not Double

Metal uses 3. With double-buffering (`FRAME_COUNT = 2`), if frame N is still being presented while frame N+1 is being rendered, the CPU has no buffer to write frame N+2 into. Triple-buffering gives one extra frame of slack, which absorbs GPU timing jitter without stalling the CPU.

### Migration Note

This change interacts with Phase 4 (`vk_buffers.zig` extraction). The `FrameResources` struct would naturally live in `vk_types.zig`, and `createFrameResources` / `destroyFrameResources` would live in `vk_buffers.zig`.

---

## 2. Batched Atlas Uploads

### The Problem

Each atlas upload (`uploadAtlasData`, `uploadSvgAtlasData`, `uploadImageAtlasData`) records a command buffer, submits it, and **blocks on a fence**:

```zig
// This pattern repeats 3 times — once per atlas type
_ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.transfer_fence);
_ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));
```

If all three atlases update in the same frame (e.g., first render after init, or a font/theme change), that's **3 sequential GPU round-trips**: submit → wait → submit → wait → submit → wait. Each fence wait is a full CPU stall while the GPU drains.

### The Fix

Record all pending atlas transfers into a **single command buffer**, then submit once:

```zig
pub fn flushAtlasUploads(self: *Self) !void {
    // Only submit if there's work to do
    if (!self.text_atlas_dirty and !self.svg_atlas_dirty and !self.image_atlas_dirty) return;

    const cmd = self.transfer_command_buffer;
    _ = vk.vkResetCommandBuffer(cmd, 0);
    _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

    // Record all pending atlas transfers
    if (self.text_atlas_dirty) {
        recordAtlasTransfer(cmd, self.atlas_image, self.staging_buffer, width, height, .r8);
        self.text_atlas_dirty = false;
    }
    if (self.svg_atlas_dirty) {
        recordAtlasTransfer(cmd, self.svg_atlas_image, self.staging_buffer, width, height, .rgba8);
        self.svg_atlas_dirty = false;
    }
    if (self.image_atlas_dirty) {
        recordAtlasTransfer(cmd, self.image_atlas_image, self.staging_buffer, width, height, .rgba8);
        self.image_atlas_dirty = false;
    }

    _ = vk.vkEndCommandBuffer(cmd);

    // Single submit, single fence wait
    _ = vk.vkResetFences(self.device, 1, &self.transfer_fence);
    _ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.transfer_fence);
    _ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, maxInt);
}
```

**Impact:** Worst case goes from 3 GPU round-trips to 1. This is most noticeable on the first frame and during theme/font changes.

### Staging Buffer Consideration

If all three atlases are dirty simultaneously, the staging buffer must be large enough for the largest single atlas (not all three — transfers are recorded sequentially within the same command buffer, so the staging buffer can be reused between copies as long as each copy completes before the next starts).

However, with a single command buffer, the GPU processes copies in order but the staging buffer contents must not be overwritten until the copy command has **read** from it (which happens during GPU execution, not during recording). Two options:

**Option A — One staging region per atlas:** Split the staging buffer into 3 regions, memcpy all data up front, then record all copies. Requires `3× max_atlas_size` staging space.

**Option B — Sequential flush per atlas:** Keep the current approach of one staging buffer but record one atlas at a time, still in the same command buffer. The GPU executes them in order, and since each barrier ensures the previous transfer completes before the next layout transition, this is safe. Uses `1× max_atlas_size` staging space.

Option B is simpler and still eliminates 2 of 3 fence waits.

### Migration Note

This naturally fits into Phase 3 (`vk_atlas.zig` extraction). The generic `uploadAtlas` function would handle staging + recording, and a new `flushAtlasUploads` function on the coordinator would batch-submit.

---

## 3. Pre-Allocate Staging Buffer at Init

### The Problem

The staging buffer is created lazily and grows dynamically during atlas uploads:

```zig
if (self.staging_buffer == null or self.staging_size < image_size) {
    // Destroy old buffer + memory
    // Create new buffer + memory + map
    self.staging_size = image_size;
}
```

If atlas sizes change (e.g., text atlas grows from 512×512 to 1024×1024), this triggers a `vkDestroyBuffer` + `vkFreeMemory` + `vkCreateBuffer` + `vkAllocateMemory` + `vkMapMemory` sequence mid-frame. This violates CLAUDE.md's "no dynamic allocation after initialization" rule and introduces unpredictable latency spikes.

### The Fix

Pre-allocate the staging buffer during `initWithWaylandSurface` to a known upper bound:

```zig
// In initWithWaylandSurface, after createBuffers:
const MAX_ATLAS_DIMENSION = 4096;
const MAX_STAGING_SIZE = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4; // 64MB for RGBA
try self.createBuffer(
    MAX_STAGING_SIZE,
    vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    &self.staging_buffer,
    &self.staging_memory,
);
_ = vk.vkMapMemory(self.device, self.staging_memory, 0, MAX_STAGING_SIZE, 0, &self.staging_mapped);
self.staging_size = MAX_STAGING_SIZE;
```

Then the upload functions simply assert instead of reallocating:

```zig
std.debug.assert(image_size <= self.staging_size); // Fail fast if assumption violated
```

If 64MB is too aggressive for low-memory targets, use a smaller default with a compile-time constant that can be tuned per platform.

---

## 4. Replace `vkDeviceWaitIdle` with Targeted Fence Waits

### The Problem

Swapchain recreation uses `vkDeviceWaitIdle`, which drains the **entire GPU**:

```zig
if (self.swapchain_needs_recreate) {
    _ = vk.vkDeviceWaitIdle(self.device);
    self.recreateSwapchain(...);
}
```

During interactive window resizing, this fires on every resize event and causes visible stutter. `vkDeviceWaitIdle` waits for _all_ queue operations to complete — including any async compute or transfer work (if added later).

### The Fix

Wait only on the in-flight frame fences:

```zig
if (self.swapchain_needs_recreate) {
    // Wait only for our frames — not ALL GPU work
    for (0..FRAME_COUNT) |i| {
        _ = vk.vkWaitForFences(self.device, 1, &self.frames[i].fence, vk.TRUE, maxInt);
    }
    self.recreateSwapchain(...);
}
```

This is semantically equivalent for the current single-queue architecture, but doesn't block on unrelated GPU work if async compute/transfer queues are added later.

---

## 5. Sub-Allocate Memory from Pools

### The Problem

Every buffer and image gets its own `vkAllocateMemory` call:

```zig
fn createBuffer(...) !void {
    vk.vkCreateBuffer(self.device, &buffer_info, null, buffer);
    vk.vkGetBufferMemoryRequirements(self.device, buffer.*, &mem_requirements);
    vk.vkAllocateMemory(self.device, &alloc_info, null, memory);
    vk.vkBindBufferMemory(self.device, buffer.*, memory.*, 0);
}
```

Current allocation count: ~10+ individual `vkAllocateMemory` calls (5 storage/uniform buffers, 1 staging, 3 atlas images, 1 MSAA image). With triple-buffering, this grows to ~20+.

Many Vulkan drivers limit total allocations to 4096. Each allocation is also a kernel round-trip.

### The Fix

Allocate a few large memory blocks at init, then sub-allocate:

```zig
const MemoryPool = struct {
    memory: vk.DeviceMemory,
    mapped: ?*anyopaque,  // null for device-local
    size: vk.DeviceSize,
    offset: vk.DeviceSize,

    fn allocate(self: *MemoryPool, requirements: vk.MemoryRequirements) !SubAllocation {
        // Align offset
        const aligned = (self.offset + requirements.alignment - 1) & ~(requirements.alignment - 1);
        std.debug.assert(aligned + requirements.size <= self.size);
        self.offset = aligned + requirements.size;
        return .{ .memory = self.memory, .offset = aligned };
    }
};
```

Two pools cover all cases:

| Pool        | Memory Properties               | Contents                                       |
| ----------- | ------------------------------- | ---------------------------------------------- |
| Host pool   | `HOST_VISIBLE \| HOST_COHERENT` | All mapped buffers (uniform, storage, staging) |
| Device pool | `DEVICE_LOCAL`                  | Atlas images, MSAA image                       |

**Impact:** Init-time only, but reduces kernel calls from ~20 to 2 and future-proofs against the 4096-allocation driver limit.

### Migration Note

This would live in `vk_buffers.zig` and replace the current `createBuffer` function with pool-aware allocation.

---

## 6. Interaction with Decomposition Phases

These performance changes map cleanly onto the existing migration phases:

| Performance Fix              | Decomposition Phase                                   | Notes                                                          |
| ---------------------------- | ----------------------------------------------------- | -------------------------------------------------------------- |
| Triple-buffered resources    | Phase 1 (`vk_types.zig`) + Phase 4 (`vk_buffers.zig`) | `FrameResources` struct in types, creation in buffers          |
| Batched atlas uploads        | Phase 3 (`vk_atlas.zig`)                              | Generic `uploadAtlas` + `flushAtlasUploads` coordinator method |
| Pre-allocated staging buffer | Phase 4 (`vk_buffers.zig`)                            | Move staging allocation to init-time                           |
| Targeted fence waits         | Phase 4 (`vk_swapchain.zig`)                          | Update `recreateSwapchain`                                     |
| Memory sub-allocation        | Phase 4 (`vk_buffers.zig`)                            | New `MemoryPool` replaces `createBuffer` internals             |
| Descriptor layout dedup      | Phase 5 (already planned)                             | No change needed                                               |

The recommended order is: **triple-buffering first** (biggest frame-time impact), then **batched atlas uploads** (biggest spike reduction), then the rest during their natural decomposition phases.
