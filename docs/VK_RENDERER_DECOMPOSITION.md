# Vulkan Renderer Decomposition & Optimization Proposal

## The Problem ✅ Solved

`vk_renderer.zig` was **4,179 lines** concentrating 8 distinct responsibilities into one file. It now follows the Metal backend's coordinator pattern: **1,132 lines** as a thin coordinator delegating to 7 focused modules (4,138 lines total across 8 files). For comparison, the Metal backend spreads similar functionality across **18 focused files** under `src/platform/macos/metal/`, with `renderer.zig` acting as a ~280-line thin coordinator.

All 5 decomposition phases and the first runtime performance improvement (triple-buffering) are complete.

---

## Original Anatomy (Pre-Decomposition)

Every function in the original monolithic file mapped to a logical domain:

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

The **pipelines** and **atlas upload** sections were the biggest offenders — nearly 1,730 lines of near-identical boilerplate. All of this has been deduplicated.

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

## File Structure ✅ Complete

```
src/platform/linux/
├── vk_renderer.zig        # Coordinator struct + public API (1,132 lines)
├── vk_types.zig           # GPU types, constants (213 lines)
├── vk_instance.zig        # Instance, device, debug messenger (412 lines)
├── vk_swapchain.zig       # Swapchain, MSAA, render pass, framebuffers (748 lines)
├── vk_buffers.zig         # Buffer creation, commands, sync objects (326 lines)
├── vk_descriptors.zig     # Descriptor layouts, pool, sets, updates (330 lines)
├── vk_pipelines.zig       # Pipeline creation via generic helper (359 lines)
├── vk_atlas.zig           # Atlas upload via generic helper (618 lines)
├── vulkan.zig             # C API bindings (635 lines)
├── scene_renderer.zig     # Batch drawing (493 lines)
└── shaders/               # SPIR-V
```

**Vulkan module total: 4,138 lines** across 8 files (down from 4,179 in one file). The line count is similar but the code is deduplicated, documented, and asserted — the ~565 lines of net growth are doc comments, error types, result types, and assertions (zero-debt infrastructure per CLAUDE.md Rule #1). The coordinator (`vk_renderer.zig`) is now 1,132 lines including the `FrameResources` struct and triple-buffered render loop.

---

## Module Designs

### 1. `vk_types.zig` — Pure data, zero Vulkan state

```zig
//! GPU types for Vulkan shader communication
pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 2048;
pub const MAX_IMAGES: u32 = 1024;
pub const FRAME_COUNT: u32 = 3;  // Triple-buffered (was MAX_FRAMES_IN_FLIGHT = 2)
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

**Rationale beyond line count:** The Metal backend doesn't have an equivalent `metal_instance.zig` because Metal's device creation is trivial (`MTLCreateSystemDefaultDevice()`). Vulkan's instance/device setup is a one-time ~280-line cost that will never be touched again after initial bringup. Extracting it isn't about deduplication — it's about getting code you'll never debug again out of your working set.

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

### Pipeline Cache

All 4 pipelines are currently created from scratch on every init. Adding a `VkPipelineCache` is trivial during extraction — pass a cache handle into `createGraphicsPipeline`, serialize to disk on shutdown, reload on startup. This makes second-and-subsequent launches faster. Low priority but nearly free to add here.

### Render Pass Compatibility

All 4 pipelines use the same render pass. This means pipeline recreation during swapchain resize is unnecessary if the swapchain format doesn't change (which it rarely does). Worth asserting during recreation:

```zig
std.debug.assert(new_format == self.swapchain_format); // If this fires, recreate pipelines too
```

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

### Phase 1 — Extract `vk_types.zig` (zero risk) ✅ Complete

Pure data move. No Vulkan state involved.

- ✅ Moved `Uniforms`, `GpuGlyph`, `GpuSvg`, `GpuImage`, and all `MAX_*` constants to `vk_types.zig` (213 lines)
- ✅ Updated `scene_renderer.zig` imports to source directly from `vk_types.zig`
- ✅ `vk_renderer.zig` re-exports all symbols for backward compatibility
- ✅ Added comptime size assertions: `Uniforms == 16`, `GpuGlyph == 64`, `GpuSvg == 80`, `GpuImage == 96`
- **Result:** vk_renderer.zig 4,179 → 4,018 (−161 lines)

### Phase 2 — Extract `vk_pipelines.zig` (biggest bang for buck) ✅ Complete

- ✅ Wrote generic `createGraphicsPipeline` function parameterized by `PipelineConfig` (shader SPV + descriptor layout + `BlendMode`)
- ✅ Replaced 4 create methods with 4 calls in new `createAllPipelines` coordinator method
- ✅ Fixed misleading "premultiplied" comment on text pipeline — text uses standard `SRC_ALPHA` blending, only SVG uses `.premultiplied`
- ✅ Deleted `createUnifiedPipeline`, `createTextPipeline`, `createSvgPipeline`, `createImagePipeline`, `createShaderModule`
- ✅ Deleted `destroyUnifiedPipeline`, `destroyTextPipeline`, `destroySvgPipeline`, `destroyImagePipeline` — replaced with `destroyPipelinePair` + `destroyAllPipelines` delegating to `vk_pipelines.destroyPipeline`
- ✅ `deinit` pipeline cleanup: 8 individual destroy calls → `self.destroyAllPipelines()`
- ✅ Fixed-function state split into small named helpers (each under 70-line limit)
- ✅ Assertions on every function entry per CLAUDE.md Rule #3
- **Result:** vk_renderer.zig 4,018 → 3,346 (−672 lines); vk_pipelines.zig = 359 lines

### Phase 3 — Extract `vk_atlas.zig` (second biggest win) ✅ Complete

- ✅ `AtlasResources` struct replaces 7 individual fields per atlas (21 total → 3 struct instances: `text_atlas`, `svg_atlas`, `image_atlas`)
- ✅ Wrote generic `uploadAtlas` parameterized by `AtlasFormat` (.r8 for text, .rgba8 for SVG/image) — handles image creation, staging, barriers, transfer, and same-size fast path
- ✅ Wrote generic `updateAtlasDescriptorSet` — replaces 3 identical ~80-line descriptor update functions (`updateTextDescriptorSet`, `updateSvgDescriptorSet`, `updateImageDescriptorSet`)
- ✅ `TransferContext` struct groups mutable staging buffer state + immutable transfer sync primitives; `makeTransferContext` builds it on the stack from `VulkanRenderer` fields (zero allocation)
- ✅ Deleted 9 methods: `uploadAtlas`, `uploadAtlasData`, `updateTextDescriptorSet`, `uploadSvgAtlas`, `uploadSvgAtlasData`, `updateSvgDescriptorSet`, `uploadImageAtlas`, `uploadImageAtlasData`, `updateImageDescriptorSet`
- ✅ Added 4 methods: `makeTransferContext` helper + 3 thin upload wrappers (~25 lines each vs ~110 each before)
- ✅ Fixed render method and `window.zig` to use `AtlasResources` fields (`self.text_atlas.view`, `self.svg_atlas.view`, `self.image_atlas.view`)
- ✅ Staging buffer lifecycle (create/resize/map) handled internally by `vk_atlas.ensureStagingCapacity` — no more `self.createBuffer` calls for staging
- ✅ Assertions on every function entry per CLAUDE.md Rule #3; dimension limits enforced via `MAX_ATLAS_DIMENSION`
- **Result:** vk_renderer.zig 3,346 → 2,336 (−1,010 lines); vk_atlas.zig = 618 lines

### Phase 4 — Extract `vk_instance.zig`, `vk_swapchain.zig`, `vk_buffers.zig`, `vk_descriptors.zig` ✅ Complete

All four modules extracted as **free functions with targeted parameters** — each function takes only what it needs, not the entire `*VulkanRenderer`. Result types return created handles; callers assign to `self`.

- ✅ **`vk_instance.zig`** (412 lines): Moved `createInstance`, `debugCallback`, `createDebugMessenger`, `destroyDebugMessenger`, `createWaylandSurface`, `pickPhysicalDevice`, `isDeviceSuitable` (renamed `findQueueFamilies`), `createLogicalDevice`. Returns `InstanceResult`, `PhysicalDeviceResult`, `DeviceResult` structs. `isDeviceSuitable` refactored to return `?QueueFamilies` instead of mutating `self` — eliminates side-effect during device enumeration.
- ✅ **`vk_swapchain.zig`** (748 lines): Moved `createSwapchain`, `createMSAAResources`, `createRenderPass`, `createFramebuffers`, `getMaxUsableSampleCount`, `destroyImageViews`, `destroyFramebuffers`. Swapchain config query split into small helpers (`chooseFormat`, `choosePresentMode`, `chooseCompositeAlpha`, `chooseExtent`, `chooseImageCount`). Render pass creation deduplicated: MSAA and simple paths share `buildRenderPass` helper. `MSAAResources` struct with `destroy` method replaces 3 separate fields.
- ✅ **`vk_buffers.zig`** (326 lines): Moved `createBuffer`, `destroyBuffer`, `createCommandPool`, `allocateCommandBuffers`, `createSyncObjects`. Added `createMappedBuffer` convenience wrapper (create + map in one call) — `createBuffers` in renderer reduced from 55 lines to 5 calls. `SyncObjects` and `CommandBuffers` structs group related handles. `SyncObjects.destroy` method handles null-safe cleanup.
- ✅ **`vk_descriptors.zig`** (325 lines): Moved all descriptor layout/pool/set logic + `createSampler` (renamed `createAtlasSampler`). `createDescriptorLayouts` collapsed from 167 lines of 4 identical binding arrays to 2 functions: `createUnifiedLayout` + `createTexturedLayout` (shared `createLayout` helper). `allocateDescriptorSets` collapsed from 60 lines of 4 identical alloc blocks to 4 calls to `allocateDescriptorSet`. `updateUnifiedDescriptorSet` extracted as free function. `createDescriptorPool` extracted.
- ✅ **`recreateSwapchain` refactored**: Now calls `vk_swapchain.createFramebuffers` instead of inlining a 45-line copy of `createFramebuffers`. Added `std.debug.assert(sc.format == self.swapchain_format)` to assert format stability on resize (CLAUDE.md Rule #11 — handle the negative space).
- ✅ **`vk_renderer.zig` coordinator pattern**: `initWithWaylandSurface` now reads as a clear sequence of labeled module calls. `deinit` uses module-level destroy functions. All `self.create*` methods replaced with module free function calls + result struct unpacking.
- **Result:** vk_renderer.zig 2,336 → 1,090 (−1,246 lines); 4 new modules totaling 1,811 lines. Net code growth ~565 lines (assertions, doc comments, result types, error types — zero-debt infrastructure per CLAUDE.md Rule #1). After triple-buffering (Runtime #1), vk_renderer.zig grew to 1,132 lines (+42 lines for `FrameResources` struct and per-frame loop logic).

### Phase 5 — Merge identical descriptor layouts ✅ Complete

Collapsed 3 identical textured descriptor layouts into 1 shared `textured_descriptor_layout` handle (Option A).

- ✅ **Struct fields**: Replaced `text_descriptor_layout`, `svg_descriptor_layout`, `image_descriptor_layout` with single `textured_descriptor_layout` field (shared by text, SVG, image pipelines).
- ✅ **`createDescriptorLayouts`**: Single `vk_descriptors.createTexturedLayout` call instead of three identical calls.
- ✅ **`destroyDescriptorLayouts`**: Destroys exactly 2 layout handles (`unified_descriptor_layout` + `textured_descriptor_layout`) — no triple-free risk.
- ✅ **`allocateDescriptorSets`**: All three textured descriptor sets allocated from the shared layout.
- ✅ **`createAllPipelines`**: Text, SVG, and image pipelines all reference `textured_descriptor_layout`.
- ✅ **`vk_descriptors.zig` doc comment**: Updated to reflect Phase 5 completion — renderer stores exactly 2 layout handles.
- **Result:** −2 struct fields, −16 lines of redundant layout creation/destruction, eliminated the `deinit` triple-free trap entirely.

---

## Summary ✅ All Phases Complete

| Metric                         | Before (original)        | After (all phases + triple-buffering) |
| ------------------------------ | ------------------------ | ------------------------------------- |
| Total lines                    | 4,179 (1 file)           | 4,138 (8 files)                       |
| Largest file                   | 4,179 (vk_renderer.zig)  | 1,132 (vk_renderer.zig coordinator)   |
| Copy-pasted pipeline code      | 660 lines (4×)           | ✅ 0 (1× generic, 359 lines)          |
| Copy-pasted atlas code         | 1,070 lines (3×)         | ✅ 0 (1× generic, 618 lines)          |
| Copy-pasted descriptor updates | 240 lines (3×)           | ✅ 0 (1× generic in vk_atlas)         |
| Descriptor layouts             | 4 (3 identical)          | ✅ 2 (unified + textured)             |
| VulkanRenderer atlas fields    | 21 individual fields     | ✅ 3 `AtlasResources` structs         |
| Frame buffering                | Single-buffered (2 sync) | ✅ Triple-buffered (`FRAME_COUNT = 3`) |
| Per-frame resource fields      | 25+ individual fields    | ✅ `frames: [3]FrameResources`         |
| Files                          | 1                        | 8                                      |

The net line count is similar (~4,138 vs 4,179) but the composition is fundamentally different: the original was ~1,730 lines of copy-paste; the new code replaces that with doc comments, assertions, error types, and result types — zero-debt infrastructure per CLAUDE.md Rule #1.

---

# Runtime Performance Improvements

The decomposition above addresses **code organization**. This section addresses **frame-time performance** — changes that make the renderer faster at runtime, independent of how the code is split across files.

## Priority Matrix

| Priority    | Issue                                                | Impact                                            |
| ----------- | ---------------------------------------------------- | ------------------------------------------------- |
| ✅ Done      | Triple-buffer storage buffers + descriptors          | Enables CPU-GPU parallelism (Metal parity)        |
| ✅ Done      | Sub-allocate memory from pools                       | Reduces ~15 `vkAllocateMemory` calls to 1         |
| ✅ Done      | Batch atlas uploads into single submission           | Eliminates ~2 GPU round-trips per atlas update    |
| ✅ Done      | Pre-allocate staging buffer at init                  | Zero mid-frame allocations (CLAUDE.md compliance) |
| ✅ Done      | Replace `vkDeviceWaitIdle` with targeted fence waits | Smoother window resize                            |
| ✅ Done      | Deduplicate descriptor layouts (3 → 1)               | Fewer Vulkan objects, no triple-free bug          |
| ✅ Done      | `recreateSwapchain` calls `createFramebuffers`       | Eliminates divergent code path                    |

**Sub-allocation results:** `MemoryPool` in `vk_buffers.zig` bump-allocates from a single 8MB host-visible `VkDeviceMemory` block. All 15 per-frame mapped buffers (5 buffer types × 3 frames) are sub-allocated at init via `createMappedBufferFromPool`. Total `vkAllocateMemory` calls reduced from ~15 to 1 (pool) + 1 (staging) + per-atlas device-local = ~5. Well under the 4096 driver limit.

---

## 1. Triple-Buffered Per-Frame Resources (Metal Parity) ✅ Complete

### The Problem

The Metal backend triple-buffers **every pipeline's instance data** (`FRAME_COUNT = 3`):

- `text.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `svg_pipeline.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `image_pipeline.zig`: `instance_buffers: [FRAME_COUNT]objc.Object`
- `polyline_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`
- `point_cloud_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`
- `colored_point_cloud_pipeline.zig`: `vertex_buffers: [FRAME_COUNT]objc.Object`

Each pipeline rotates via `nextFrame()` at the start of each frame, so the CPU writes to buffer N while the GPU reads from buffer N-1 and N-2. No contention, no stalls.

The Vulkan backend had `MAX_FRAMES_IN_FLIGHT = 2` but only **one** set of storage buffers shared across all frames:

```zig
// Was: single-buffered — CPU and GPU fought over the same memory
primitive_buffer: vk.Buffer = null,
glyph_buffer: vk.Buffer = null,
svg_buffer: vk.Buffer = null,
image_buffer: vk.Buffer = null,
uniform_buffer: vk.Buffer = null,
```

This forced the fence wait at the top of `render()` to be **blocking** — the CPU could not start writing frame N+1's data until the GPU finished reading frame N's data from the same buffer.

```
Old timeline (serialized):
CPU: [wait fence]---[write buffers + record]---[submit]---[wait fence]---...
GPU:               [idle]                      [render]                 [idle]
```

### The Fix ✅ Implemented

Introduced a `FrameResources` struct in `vk_renderer.zig` and triple-buffered it:

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

### ⚠️ FRAME_COUNT Consistency ✅ Enforced

`MAX_FRAMES_IN_FLIGHT` has been deleted and all uses replaced with `FRAME_COUNT`. The `FrameResources` struct bundles sync objects with buffers, making it impossible for array sizes to diverge. Zero references to `MAX_FRAMES_IN_FLIGHT` remain project-wide.

### VRAM Budget Sketch (CLAUDE.md Rule #7)

Back-of-envelope for triple-buffered resource usage:

| Resource                  | Per-Frame Size | × 3 Frames | Total       |
| ------------------------- | -------------- | ----------- | ----------- |
| Primitive storage buffer  | 4096 × 128B   | 1.5 MB      | 1.5 MB      |
| Glyph storage buffer      | 8192 × 64B    | 1.5 MB      | 1.5 MB      |
| SVG storage buffer        | 2048 × 80B    | 480 KB      | 480 KB      |
| Image storage buffer      | 1024 × 96B    | 288 KB      | 288 KB      |
| Uniform buffer            | 16B            | 48B         | ~0          |
| **Subtotal (host-vis)**   |                |             | **~3.75 MB** |
| Staging buffer (shared)   | 256 MB         | 1×          | 256 MB      |
| Atlas images (device-local)| varies        | 1× (shared) | varies      |
| MSAA image (device-local) | W×H×4×samples | 1×          | varies      |

Total host-visible: **~260 MB**. Total device-local: depends on atlas/MSAA resolution. At 4K MSAA 4×, the MSAA image alone is ~128 MB. This is well within desktop GPU budgets but worth tracking. (The staging buffer dominates at 256 MB — `MAX_ATLAS_DIMENSION = 8192` in `vk_atlas.zig`.)

With memory sub-allocation (improvement #5), all host-visible buffers come from a single ~260 MB pool (1 `vkAllocateMemory` call), and all device-local resources from a second pool.

### Migration Note ✅ Complete

Implemented in `vk_renderer.zig` (coordinator pattern — `FrameResources` defined locally since it contains Vulkan handles, keeping `vk_types.zig` pure-data). Changes:

- ✅ **`vk_types.zig`**: Renamed `MAX_FRAMES_IN_FLIGHT = 2` → `FRAME_COUNT = 3`.
- ✅ **`vk_buffers.zig`**: All `SyncObjects`, `CommandBuffers` arrays sized by `FRAME_COUNT`. Creation functions produce 3 of everything.
- ✅ **`vk_descriptors.zig`**: Pool sized for `4 × FRAME_COUNT = 12` descriptor sets. Per-type counts scaled accordingly.
- ✅ **`vk_renderer.zig`**: Defined `FrameResources` struct bundling per-frame buffers + descriptor sets + sync objects + command buffer. Replaced 25+ individual fields with `frames: [FRAME_COUNT]FrameResources`. `render()` indexes `frames[current_frame]`, waits only on that frame's fence. `createFrameBuffers()` loops over all frames. `updateUniformBuffer()` writes all frames. Atlas uploads update ALL frames' descriptor sets (any frame could render next). `destroyFrameResources()` replaces `destroySyncObjects` + `destroyAllBuffers`.
- ✅ **`MAX_FRAMES_IN_FLIGHT` eliminated**: Zero references remain project-wide. All code uses `FRAME_COUNT`.
- **Result:** CPU can now write frame N+1 while GPU renders frame N. ~3.75 MB additional host-visible VRAM (well within budget). ~15 `vkAllocateMemory` calls total (safe; sub-allocation is next priority).

---

## 2. Batched Atlas Uploads ✅ Complete

### The Problem

Each atlas upload (`uploadAtlasData`, `uploadSvgAtlasData`, `uploadImageAtlasData`) records a command buffer, submits it, and **blocks on a fence**:

```zig
// This pattern repeats 3 times — once per atlas type
_ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.transfer_fence);
_ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));
```

If all three atlases update in the same frame (e.g., first render after init, or a font/theme change), that's **3 sequential GPU round-trips**: submit → wait → submit → wait → submit → wait. Each fence wait is a full CPU stall while the GPU drains.

### The Fix ✅ Implemented

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

If all three atlases are dirty simultaneously, the staging buffer must be large enough for all pending data — not just one atlas at a time. The key constraint: copy commands read from the staging buffer during **GPU execution**, not during **recording**. When recording multiple copy commands into a single command buffer, the CPU has already returned from `vkCmdCopyBufferToImage` before the GPU reads the staging data. If you overwrite the staging buffer between recording two copies, the second copy clobbers the first's source data.

**Option A — Sub-divided staging regions (recommended):** Split the pre-allocated staging buffer into regions. Memcpy all dirty atlas data into separate offsets up front, then record all copy commands referencing their respective regions. Each `vkCmdCopyBufferToImage` points to a different `bufferOffset`.

```zig
// With a 256MB staging buffer (from improvement #3, MAX_ATLAS_DIMENSION=8192), subdivide:
// Region 0: [0, max_atlas_size)         — text atlas
// Region 1: [max_atlas_size, 2×max)     — SVG atlas
// Region 2: [2×max, 3×max)              — image atlas
const region_offset = atlas_index * MAX_SINGLE_ATLAS_SIZE;
const dest: [*]u8 = @ptrCast(staging_mapped);
@memcpy(dest[region_offset..][0..data.len], data);

// Then record copy with bufferOffset = region_offset
copy_region.bufferOffset = region_offset;
```

This uses `3× max_single_atlas_size` staging space (well within the 256 MB pre-allocation from improvement #3) and is safe because each copy reads from a non-overlapping region.

**Option B — Sequential submit per atlas:** Record and submit one atlas at a time, reusing the same staging region. This is the current approach minus 2 fence waits — but it still requires one fence wait per atlas because you must ensure the GPU has finished reading the staging buffer before overwriting it for the next atlas. This **does not** eliminate the round-trips; it only reduces overhead slightly.

**Option A is correct.** Option B doesn't achieve the goal of single-submission batching. The 256 MB staging buffer from improvement #3 provides more than enough room for 3 simultaneous atlas regions.

### Migration Note ✅ Complete

Implemented across `vk_atlas.zig` and `vk_renderer.zig`:

- ✅ **`vk_atlas.zig`**: Added `prepareAtlasUpload()` — copies pixel data into a designated staging region and (re)creates the atlas image if dimensions changed, but does NOT record or submit any command buffer. Added `recordAtlasTransfer()` — records barrier → copy → barrier into an already-begun command buffer at a specified `staging_offset`.
- ✅ **`vk_renderer.zig`**: `uploadAtlas`, `uploadSvgAtlas`, `uploadImageAtlas` now call `prepareAtlasUpload` and set dirty flags. New `flushAtlasUploads()` method is called at the top of `render()` — it checks all three dirty flags, begins a single command buffer with `ONE_TIME_SUBMIT_BIT`, records all pending transfers, and submits once with a single fence wait.
- ✅ **Staging regions**: Three non-overlapping regions within the pre-allocated staging buffer (`STAGING_REGION_TEXT = 0`, `STAGING_REGION_SVG = MAX_SINGLE_ATLAS_BYTES`, `STAGING_REGION_IMAGE = 2 × MAX_SINGLE_ATLAS_BYTES`). Each `vkCmdCopyBufferToImage` reads from its own region — no clobbering.
- **Result:** Worst case goes from 3 sequential GPU round-trips to 1. Most noticeable on first frame and during theme/font changes.

---

## 3. Pre-Allocate Staging Buffer at Init ✅ Complete

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

### The Fix ✅ Implemented

Pre-allocate the staging buffer during `initWithWaylandSurface` to a known upper bound:

```zig
// In initWithWaylandSurface, after createBuffers:
const MAX_ATLAS_DIMENSION = 8192;
const MAX_STAGING_SIZE = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4; // 256MB for RGBA
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

If 256MB is too aggressive for low-memory targets, use a smaller default with a compile-time constant that can be tuned per platform.

### Migration Note ✅ Complete

- ✅ **`vk_atlas.zig`**: Exported `MAX_SINGLE_ATLAS_BYTES`, `STAGING_REGION_COUNT`, and `MAX_STAGING_BYTES` (= 3 × `MAX_SINGLE_ATLAS_BYTES` = 768MB for 3 simultaneous 8192×8192 RGBA regions). The `ensureStagingCapacity` path remains as a fallback for the legacy `uploadAtlas` codepath but is no longer exercised by the batched upload flow.
- ✅ **`vk_renderer.zig`**: Staging buffer is pre-allocated via `vk_buffers.createMappedBuffer` during `initWithWaylandSurface`, sized to `vk_atlas.MAX_STAGING_BYTES`. The `TransferContext` staging fields still point to the renderer's pre-allocated buffer.

---

## 4. Replace `vkDeviceWaitIdle` with Targeted Fence Waits ✅ Complete

### The Problem

Swapchain recreation uses `vkDeviceWaitIdle`, which drains the **entire GPU**:

```zig
if (self.swapchain_needs_recreate) {
    _ = vk.vkDeviceWaitIdle(self.device);
    self.recreateSwapchain(...);
}
```

During interactive window resizing, this fires on every resize event and causes visible stutter. `vkDeviceWaitIdle` waits for _all_ queue operations to complete — including any async compute or transfer work (if added later).

### The Fix ✅ Implemented

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

## 5. Sub-Allocate Memory from Pools ✅ Complete

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

Many Vulkan drivers limit total allocations to 4096. Each allocation is also a kernel round-trip. **This is why sub-allocation must land alongside triple-buffering, not after it** — tripling allocation count without pooling risks hitting driver limits on Intel/mobile GPUs.

### The Fix ✅ Implemented

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

### Migration Note ✅ Complete

- ✅ **`vk_buffers.zig`**: Added `MemoryPool` struct with `init`, `allocate`, `reset`, `destroy`. Added `SubAllocation` result type. Added `createBufferFromPool` and `createMappedBufferFromPool` convenience functions. Added `destroyBufferOnly` for pool-backed buffers (destroy VkBuffer handle without freeing memory). Pool uses a probe buffer at init to discover valid `memoryTypeBits`, then allocates a single large `VkDeviceMemory` and maps it if host-visible.
- ✅ **`vk_renderer.zig`**: Added `host_memory_pool` field and `HOST_POOL_SIZE = 8MB` constant (back-of-envelope: 5 buffers × 3 frames × ~260KB avg ≈ 3.9MB + alignment headroom). Pool is created in `initWithWaylandSurface` before `createFrameBuffers`. `createFrameBuffers` now calls `createMappedBufferFromPool` instead of `createMappedBuffer`. `destroyFrameResources` calls `destroyBufferOnly` (buffer handles only). Pool is destroyed in `deinit` after frame resources.
- **Result:** 15 individual `vkAllocateMemory` calls for per-frame buffers reduced to 1 pool allocation. Device-local allocations (atlas images, MSAA) remain individual for now since their sizes are dynamic.

---

## 6. Future: Dedicated Transfer Queue

The current code submits atlas transfers on the graphics queue. If the device exposes a dedicated transfer queue family (`VK_QUEUE_TRANSFER_BIT` without `VK_QUEUE_GRAPHICS_BIT`), atlas uploads can overlap with rendering entirely — truly async transfers with no render stalls.

This is not actionable today (single-queue is correct for now), but the `TransferContext` abstraction proposed in `vk_atlas.zig` sets it up cleanly: swap the queue handle and add a queue ownership transfer barrier, and the rest of the code stays the same.

---

## 7. Interaction with Decomposition Phases ✅ All Complete

All performance changes have landed in their designated modules:

| Performance Fix              | Status      | Landing Site                          | Notes                                                          |
| ---------------------------- | ----------- | ------------------------------------- | -------------------------------------------------------------- |
| Triple-buffered resources    | ✅ Done     | `vk_renderer.zig` + `vk_buffers.zig` | `FrameResources` in renderer, `FRAME_COUNT` in types           |
| Memory sub-allocation        | ✅ Done     | `vk_buffers.zig`                      | `MemoryPool` reduces 15 frame-buffer allocations to 1          |
| Batched atlas uploads        | ✅ Done     | `vk_atlas.zig` + `vk_renderer.zig`   | `prepareAtlasUpload` + `recordAtlasTransfer` + `flushAtlasUploads` |
| Pre-allocated staging buffer | ✅ Done     | `vk_renderer.zig`                     | Staging buffer allocated at init, sized for 3 concurrent atlas regions |
| Targeted fence waits         | ✅ Done     | `vk_renderer.zig`                     | `vkDeviceWaitIdle` replaced in both `resize()` and `render()` swapchain paths |
| Descriptor layout dedup      | ✅ Done     | Phase 5                               | 3 identical → 1 shared `textured_descriptor_layout`            |

---

# Further Performance Opportunities

All seven items from the original priority matrix are complete. The following opportunities were identified by auditing the implementation against the design doc and CLAUDE.md rules. They are ordered by effort/risk, lowest first.

## Priority Matrix

| Priority | Opportunity                              | Effort   | Impact                                      | Category   |
| -------- | ---------------------------------------- | -------- | ------------------------------------------- | ---------- |
| 8        | Pipeline cache (`VkPipelineCache`)       | Trivial  | Faster cold starts on subsequent launches   | Init-time  |
| 9        | Shared pipeline layouts (4 → 2 handles)  | Small    | 2 fewer Vulkan objects, simpler teardown    | Cleanup    |
| 10       | Right-size staging buffer (768 → ≤192MB) | Small    | ~500MB less host-visible memory at init     | Memory     |
| 11       | Device-local memory pool                 | Medium   | Fewer `vkAllocateMemory` calls on resize    | Resize     |
| 12       | Incremental atlas uploads                | Medium   | Less staging memcpy + GPU bandwidth per frame | Frame time |
| 13       | Separate upload/record passes            | Medium   | Better CPU cache utilization during render  | Frame time |
| 14       | Dedicated transfer queue                 | Large    | Async atlas uploads overlapped with render  | Frame time |

---

## 8. Pipeline Cache (`VkPipelineCache`)

### The Problem

All 4 pipelines are created from scratch every time `initWithWaylandSurface` runs. The document already noted this at the original Pipeline Cache section (line 225) but it was never implemented. `vk_pipelines.zig` passes `null` for the cache handle:

```zig
// vk_pipelines.zig, createPipeline():
const result = vk.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline);
//                                                   ^^^^
//                                           no pipeline cache
```

On some drivers (especially Intel and AMD), shader compilation dominates pipeline creation time. A pipeline cache lets the driver skip redundant compilation on second-and-subsequent launches.

### The Fix

1. Add a `VkPipelineCache` parameter to `createGraphicsPipeline` in `vk_pipelines.zig`.
2. Create the cache in `initWithWaylandSurface`, before `createAllPipelines`.
3. Pass it through `createAllPipelines` → `createGraphicsPipeline` → `vkCreateGraphicsPipelines`.
4. On shutdown, serialize via `vkGetPipelineCacheData` → write to `$XDG_CACHE_HOME/gooey/pipeline_cache.bin`.
5. On startup, attempt to load and pass to `vkCreatePipelineCache`. If the file is missing or corrupt, create an empty cache (Vulkan handles this gracefully).

```zig
// vk_pipelines.zig — updated signature
pub fn createGraphicsPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    sample_count: c_uint,
    config: PipelineConfig,
    pipeline_cache: vk.PipelineCache,  // nullable — null = no cache
) PipelineError!PipelineResult {
    ...
    const result = vk.vkCreateGraphicsPipelines(device, pipeline_cache, 1, &pipeline_info, null, &pipeline);
    ...
}
```

**Risk:** Near zero. A null or invalid cache falls back to uncached creation.

---

## 9. Shared Pipeline Layouts (4 → 2 Handles)

### The Problem

Text, SVG, and image pipelines all use `textured_descriptor_layout` (Phase 5 dedup), yet each `createGraphicsPipeline` call creates its own `VkPipelineLayout` handle via the internal `createPipelineLayout` helper. The renderer stores 4 separate layout handles:

```zig
// vk_renderer.zig, VulkanRenderer fields:
unified_pipeline_layout: vk.PipelineLayout = null,  // uses unified_descriptor_layout
text_pipeline_layout: vk.PipelineLayout = null,      // uses textured_descriptor_layout
svg_pipeline_layout: vk.PipelineLayout = null,        // uses textured_descriptor_layout
image_pipeline_layout: vk.PipelineLayout = null,      // uses textured_descriptor_layout
```

The three textured layouts are created from the same `VkDescriptorSetLayout` with zero push constant ranges — they produce identical `VkPipelineLayout` objects. That's 2 unnecessary Vulkan handles and 2 unnecessary `vkDestroyPipelineLayout` calls in teardown.

### The Fix

Create the `VkPipelineLayout` for each distinct descriptor layout **once**, then pass it into pipeline creation instead of creating it inside:

```zig
// Option A: Pre-create layouts in createAllPipelines, share across text/svg/image
const textured_pipeline_layout = try vk_pipelines.createPipelineLayout(device, self.textured_descriptor_layout);
// Pass to all three textured pipeline creations
```

This requires either:
- Exposing `createPipelineLayout` as public in `vk_pipelines.zig` and adding an optional `PipelineLayout` field to `PipelineConfig`, or
- Adding a `createGraphicsPipelineWithLayout` variant that accepts an existing layout.

The `PipelineResult` would then only return the `VkPipeline`, not the layout. The renderer stores 2 layouts (`unified_pipeline_layout`, `textured_pipeline_layout`) and 4 pipelines.

**Risk:** Low. The `scene_renderer.zig` `Pipelines` struct already passes layouts per-pipeline — it would pass the shared layout for text/svg/image.

---

## 10. Right-Size Staging Buffer (768MB → ≤192MB)

### The Problem

The staging buffer is pre-allocated at init for 3 concurrent 8192×8192 RGBA regions:

```zig
// vk_atlas.zig:
pub const MAX_ATLAS_DIMENSION = 8192;
pub const MAX_SINGLE_ATLAS_BYTES = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4;  // 256MB
pub const STAGING_REGION_COUNT = 3;
pub const MAX_STAGING_BYTES = MAX_SINGLE_ATLAS_BYTES * STAGING_REGION_COUNT;       // 768MB
```

768MB of host-visible memory is aggressive. The VRAM budget sketch in improvement #1 assumed 256MB. In practice:
- Text atlas: typically 1024×1024 R8 = 1MB
- SVG atlas: typically 2048×2048 RGBA = 16MB
- Image atlas: typically 2048×2048 RGBA = 16MB

Even at 4096×4096 max, the three regions total 192MB (4096² × 4 × 3). On integrated GPUs (Intel UHD, AMD APU) where host-visible memory is system RAM, 768MB is a meaningful chunk.

### The Fix

**Option A — Reduce `MAX_ATLAS_DIMENSION` to 4096:**

```zig
pub const MAX_ATLAS_DIMENSION = 4096;
// MAX_SINGLE_ATLAS_BYTES = 4096 * 4096 * 4 = 64MB
// MAX_STAGING_BYTES = 64MB * 3 = 192MB
```

4096×4096 supports ~16 million RGBA pixels per atlas — plenty for UI workloads. If a future use case needs 8K atlases, bump it then.

**Option B — Per-format staging regions:**

The text atlas is R8 (1 byte/pixel), not RGBA (4 bytes/pixel). Currently all three regions are sized for RGBA. Sizing the text region for R8 saves 75% of that region:

```zig
const TEXT_STAGING_SIZE = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 1;    // R8
const RGBA_STAGING_SIZE = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4;    // RGBA
const MAX_STAGING_BYTES = TEXT_STAGING_SIZE + 2 * RGBA_STAGING_SIZE;        // ~576MB at 8K, ~144MB at 4K
```

**Option A + B combined** at 4096: `4096² × 1 + 2 × 4096² × 4 = 16MB + 128MB = 144MB`.

**Risk:** Low. Assert on actual atlas dimensions at upload time catches any violation.

---

## 11. Device-Local Memory Pool

### The Problem

The host-visible `MemoryPool` in `vk_buffers.zig` successfully reduced ~15 frame-buffer allocations to 1. However, device-local allocations remain individual:

- **MSAA image:** `allocateMSAAMemory` in `vk_swapchain.zig` calls `vkAllocateMemory` directly. This fires on every swapchain recreate (window resize).
- **Atlas images:** `allocateImageMemory` in `vk_atlas.zig` calls `vkAllocateMemory` directly. This fires when atlas dimensions change (rare but possible).

The implementation note in improvement #5 acknowledged this:

> *"Device-local allocations (atlas images, MSAA) remain individual for now since their sizes are dynamic."*

At steady state (no resize, no atlas growth) this costs nothing. During interactive resize it's one `vkAllocateMemory` + `vkFreeMemory` per resize event for the MSAA image.

### The Fix

Create a device-local `MemoryPool` at init, sized for worst-case MSAA + atlas images:

```zig
// Back-of-envelope (CLAUDE.md Rule #7):
// MSAA at 4K (3840×2160), 4× samples, RGBA:  3840 × 2160 × 4 × 4 = ~126MB
// 3 atlas images at 4096², RGBA:               3 × 4096 × 4096 × 4 = ~192MB
// Total:                                        ~320MB device-local
const DEVICE_POOL_SIZE = 384 * 1024 * 1024; // 384MB with headroom
```

The pool needs a `reset` + re-sub-allocate path for resize (MSAA size changes but atlases don't). A simple approach: sub-allocate MSAA from the end (grows/shrinks with resize), atlases from the beginning (stable). Or keep the existing `MemoryPool.reset()` and re-allocate all device-local resources after resize.

**Complication:** `VkImage` memory requirements aren't known until after `vkCreateImage` + `vkGetImageMemoryRequirements`. The pool must handle variable alignment. The existing `MemoryPool.allocate` already aligns — this should work.

**Risk:** Medium. Image tiling requirements and memory type compatibility need careful validation. Different image formats may require different memory type bits. Assert `memoryTypeBits` compatibility at sub-allocation time.

---

## 12. Incremental Atlas Uploads

### The Problem

When an atlas is dirty, `prepareAtlasUpload` memcpys the **entire** atlas into the staging buffer, and `recordAtlasTransfer` copies the **entire** image extent to the GPU:

```zig
// vk_atlas.zig, prepareAtlasUpload():
@memcpy(base[offset..][0..data.len], data);  // full atlas data

// vk_atlas.zig, recordAtlasTransfer():
.imageExtent = .{ .width = width, .height = height, .depth = 1 },  // full image
```

For the text atlas, adding a single new glyph re-uploads the entire texture. At 2048×2048 R8 that's 4MB; at 4096×4096 it's 16MB. The CPU-side memcpy and GPU-side transfer are both proportional to total atlas size, not to the number of dirty pixels.

### The Fix

Track dirty regions per atlas and upload only changed sub-rectangles:

1. **`AtlasResources` gains a dirty rect list:**

```zig
const MAX_DIRTY_RECTS = 32;

pub const DirtyRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const AtlasResources = struct {
    // ...existing fields...
    dirty_rects: [MAX_DIRTY_RECTS]DirtyRect = undefined,
    dirty_count: u32 = 0,
};
```

2. **`prepareAtlasUpload` accepts a dirty rect** (or falls back to full-image if none provided). Only the dirty sub-region is memcpy'd into the staging buffer. Multiple dirty rects get multiple `VkBufferImageCopy` regions in a single `vkCmdCopyBufferToImage` call.

3. **The image layout transition uses `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL → TRANSFER_DST_OPTIMAL`** instead of `UNDEFINED → TRANSFER_DST_OPTIMAL` for partial updates (preserving existing contents).

**Prerequisite:** The caller (text system, SVG rasterizer) must track which atlas regions changed. This is an API contract change — the `uploadAtlas` signature would need a dirty rect parameter.

**Risk:** Medium. Partial uploads require careful barrier management (can't transition from UNDEFINED if preserving content). The staging buffer layout changes from one contiguous block per atlas to a set of sub-rectangles. The complexity is justified once atlas sizes routinely exceed ~4MB.

---

## 13. Separate Upload and Record Passes in `drawScene`

### The Problem

`scene_renderer.zig` interleaves CPU memory writes with Vulkan command recording inside the batch loop:

```zig
// For each batch:
// 1. memcpy instance data into mapped buffer  ← CPU memory write
// 2. vkCmdBindPipeline / vkCmdBindDescriptorSets  ← command recording
// 3. vkCmdDraw  ← command recording
// ...next batch: back to memcpy...
```

This ping-pongs the CPU between two different memory access patterns: sequential writes to mapped GPU memory (write-combined, uncacheable on most platforms) and Vulkan driver command encoding (driver-internal data structures). Write-combined memory has high latency for individual writes; the CPU benefits from sustained sequential writes without interruption.

### The Fix

Split `drawScene` into two passes:

**Pass 1 — Upload all instance data:**
Iterate batches, memcpy all primitive/glyph/svg/image data into their mapped buffers. Track counts and offsets but don't touch Vulkan commands.

**Pass 2 — Record all draw commands:**
Iterate the same batch sequence, bind pipelines and issue `vkCmdDraw` calls using the offsets computed in pass 1.

```zig
pub fn drawScene(cmd: vk.CommandBuffer, scene: *const Scene, pipelines: Pipelines) BatchCounts {
    var iter = BatchIterator.init(scene);

    // Pass 1: upload all instance data, collect draw list
    var draw_list: [MAX_DRAW_CALLS]DrawEntry = undefined;
    var draw_count: u32 = 0;
    // ...iterate batches, memcpy, record DrawEntry{pipeline_kind, offset, count}...

    // Pass 2: record commands from draw list
    var current_pipeline: ?PipelineKind = null;
    for (draw_list[0..draw_count]) |entry| {
        // bind pipeline if changed, then vkCmdDraw
    }

    return counts;
}
```

**Impact estimate (CLAUDE.md Rule #7):** At 1000 primitives + 500 glyphs, pass 1 writes ~200KB to write-combined memory in one burst. Pass 2 records ~10 draw calls. The savings come from avoiding write-combined latency penalties during command recording. Most measurable on integrated GPUs where write-combined performance is more variable.

**Risk:** Low. Pure refactor of `drawScene` internals. The `BatchIterator` is already deterministic (same input → same batch sequence), so iterating twice is safe. Adds a fixed-size `draw_list` array on the stack (bounded by `MAX_DRAW_CALLS`).

---

## 14. Dedicated Transfer Queue

(Expanded from item #6 above.)

### The Problem

`flushAtlasUploads` submits atlas transfer commands on the **graphics queue** and blocks with a **synchronous fence wait** before rendering begins:

```zig
// vk_renderer.zig, flushAtlasUploads():
_ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.transfer_fence);
_ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));
```

This means atlas uploads and rendering are fully serialized on the same queue. If an atlas upload takes 2ms, that's 2ms added to frame time with the CPU stalled.

### The Fix

1. **Query for a dedicated transfer queue family** during `pickPhysicalDevice` — look for `VK_QUEUE_TRANSFER_BIT` without `VK_QUEUE_GRAPHICS_BIT`.
2. **Create a separate `VkQueue`** from that family during `createLogicalDevice`.
3. **Submit atlas transfers on the transfer queue** with a `VkSemaphore` signal.
4. **Add the semaphore as a wait dependency** in the render submit's `pWaitSemaphores` (alongside the `image_available_semaphore`).
5. **Add queue ownership transfer barriers** in `recordAtlasTransfer`: release on transfer queue, acquire on graphics queue.

```zig
// Render submit waits on both semaphores:
const wait_semaphores = [_]vk.Semaphore{ frame.image_available_semaphore, self.atlas_transfer_semaphore };
const wait_stages = [_]u32{
    vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
};
```

The `TransferContext` abstraction in `vk_atlas.zig` already isolates queue and command buffer usage, so the queue swap is localized.

**Fallback:** If no dedicated transfer queue exists (some Intel GPUs), fall back to the current single-queue path. This is a runtime capability check, not a hard requirement.

**Risk:** High. Queue ownership transfers are a common source of validation errors. Requires careful barrier placement and testing across multiple GPU vendors. The semaphore-based sync replaces the simpler fence wait, adding complexity to the render loop. Worth deferring until atlas uploads become a measured bottleneck.
