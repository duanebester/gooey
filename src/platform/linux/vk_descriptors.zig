//! Descriptor layout, pool, set creation and updates.
//!
//! Free functions with targeted parameters — each takes only what it needs,
//! not the entire VulkanRenderer. Two distinct layout shapes exist:
//!
//!   - **Unified**: storage buffer (binding 0) + uniform buffer (binding 1)
//!   - **Textured**: storage + uniform + sampled image (binding 2) + sampler (binding 3)
//!
//! Text, SVG, and image pipelines all share a single textured layout handle
//! (Phase 5 complete). The renderer stores exactly 2 layout handles:
//! `unified_descriptor_layout` and `textured_descriptor_layout`.

const std = @import("std");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");

const FRAME_COUNT = vk_types.FRAME_COUNT;

// =============================================================================
// Limits (CLAUDE.md Rule #4 — put a limit on everything)
// =============================================================================

/// Maximum descriptor sets the pool can allocate.
/// 4 pipelines × FRAME_COUNT frames = 12 sets for triple-buffering.
const MAX_DESCRIPTOR_SETS: u32 = 4 * FRAME_COUNT;

// =============================================================================
// Error Types
// =============================================================================

pub const LayoutError = error{
    DescriptorSetLayoutCreationFailed,
};

pub const PoolError = error{
    DescriptorPoolCreationFailed,
};

pub const AllocError = error{
    DescriptorSetAllocationFailed,
};

pub const SamplerError = error{
    SamplerCreationFailed,
};

// =============================================================================
// Public API — Layouts
// =============================================================================

/// Create the unified descriptor set layout: storage buffer + uniform buffer.
///
/// Used by the primitive/unified pipeline which has no texture sampling.
///
///   binding 0: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER  (vertex stage)
///   binding 1: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER  (vertex + fragment stage)
pub fn createUnifiedLayout(device: vk.Device) LayoutError!vk.DescriptorSetLayout {
    std.debug.assert(device != null);

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
    };

    return createLayout(device, &bindings, bindings.len);
}

/// Create the textured descriptor set layout: storage + uniform + image + sampler.
///
/// Used by text, SVG, and image pipelines — all three share this identical layout.
/// The caller creates one handle per pipeline (Phase 5 will share a single handle).
///
///   binding 0: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER   (vertex stage)
///   binding 1: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER   (vertex stage)
///   binding 2: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE    (fragment stage)
///   binding 3: VK_DESCRIPTOR_TYPE_SAMPLER          (fragment stage)
pub fn createTexturedLayout(device: vk.Device) LayoutError!vk.DescriptorSetLayout {
    std.debug.assert(device != null);

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 2,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 3,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
    };

    return createLayout(device, &bindings, bindings.len);
}

// =============================================================================
// Public API — Pool
// =============================================================================

/// Create a descriptor pool sized for all pipelines.
///
/// Pool sizes are budgeted for 4 pipelines (unified + text + SVG + image),
/// each with their own descriptor set. Enough headroom for the current
/// architecture; triple-buffering (future Phase) will require resizing.
pub fn createDescriptorPool(device: vk.Device) PoolError!vk.DescriptorPool {
    std.debug.assert(device != null);

    // 4 pipelines × FRAME_COUNT frames for storage + uniform;
    // 3 textured pipelines × FRAME_COUNT frames for image + sampler.
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 * FRAME_COUNT },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 4 * FRAME_COUNT },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 3 * FRAME_COUNT },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 3 * FRAME_COUNT },
    };

    const pool_info = vk.DescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = MAX_DESCRIPTOR_SETS,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    var pool: vk.DescriptorPool = null;
    const result = vk.vkCreateDescriptorPool(device, &pool_info, null, &pool);
    if (!vk.succeeded(result)) return PoolError.DescriptorPoolCreationFailed;

    std.debug.assert(pool != null);
    return pool;
}

// =============================================================================
// Public API — Set Allocation
// =============================================================================

/// Allocate a single descriptor set from the pool for the given layout.
///
/// Caller is responsible for calling this once per pipeline that needs a set.
/// The pool owns the memory; sets are freed implicitly when the pool is destroyed.
pub fn allocateDescriptorSet(
    device: vk.Device,
    pool: vk.DescriptorPool,
    layout: vk.DescriptorSetLayout,
) AllocError!vk.DescriptorSet {
    std.debug.assert(device != null);
    std.debug.assert(pool != null);
    std.debug.assert(layout != null);

    const layouts = [_]vk.DescriptorSetLayout{layout};
    const alloc_info = vk.DescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layouts,
    };

    var descriptor_set: vk.DescriptorSet = null;
    const result = vk.vkAllocateDescriptorSets(device, &alloc_info, &descriptor_set);
    if (!vk.succeeded(result)) return AllocError.DescriptorSetAllocationFailed;

    std.debug.assert(descriptor_set != null);
    return descriptor_set;
}

// =============================================================================
// Public API — Descriptor Updates
// =============================================================================

/// Update the unified descriptor set with storage and uniform buffer bindings.
///
/// This writes both bindings in a single vkUpdateDescriptorSets call:
///   binding 0 → primitive storage buffer
///   binding 1 → uniform buffer (viewport dimensions)
pub fn updateUnifiedDescriptorSet(
    device: vk.Device,
    descriptor_set: vk.DescriptorSet,
    primitive_buffer: vk.Buffer,
    primitive_range: vk.DeviceSize,
    uniform_buffer: vk.Buffer,
    uniform_range: vk.DeviceSize,
) void {
    std.debug.assert(device != null);
    std.debug.assert(descriptor_set != null);
    std.debug.assert(primitive_buffer != null);
    std.debug.assert(uniform_buffer != null);

    const buffer_infos = [_]vk.DescriptorBufferInfo{
        .{
            .buffer = primitive_buffer,
            .offset = 0,
            .range = primitive_range,
        },
        .{
            .buffer = uniform_buffer,
            .offset = 0,
            .range = uniform_range,
        },
    };

    const writes = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_infos[0],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_infos[1],
            .pTexelBufferView = null,
        },
    };

    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

// =============================================================================
// Public API — Sampler
// =============================================================================

/// Create a linear-filtering, clamp-to-edge sampler for atlas textures.
///
/// Shared across all atlas pipelines (text, SVG, image). A single sampler
/// handle is sufficient since all atlases use the same filtering mode.
pub fn createAtlasSampler(device: vk.Device) SamplerError!vk.Sampler {
    std.debug.assert(device != null);

    const sampler_info = vk.SamplerCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = vk.VK_FILTER_LINEAR,
        .minFilter = vk.VK_FILTER_LINEAR,
        .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipLodBias = 0,
        .anisotropyEnable = vk.FALSE,
        .maxAnisotropy = 1,
        .compareEnable = vk.FALSE,
        .compareOp = vk.VK_COMPARE_OP_NEVER,
        .minLod = 0,
        .maxLod = 0,
        .borderColor = vk.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        .unnormalizedCoordinates = vk.FALSE,
    };

    var sampler: vk.Sampler = null;
    const result = vk.vkCreateSampler(device, &sampler_info, null, &sampler);
    if (!vk.succeeded(result)) return SamplerError.SamplerCreationFailed;

    std.debug.assert(sampler != null);
    return sampler;
}

// =============================================================================
// Internal Helpers
// =============================================================================

/// Shared layout creation — all layouts use this path, only bindings differ.
fn createLayout(
    device: vk.Device,
    bindings: [*]const vk.DescriptorSetLayoutBinding,
    binding_count: u32,
) LayoutError!vk.DescriptorSetLayout {
    std.debug.assert(device != null);
    std.debug.assert(binding_count >= 2); // All layouts have at least storage + uniform

    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = binding_count,
        .pBindings = bindings,
    };

    var layout: vk.DescriptorSetLayout = null;
    const result = vk.vkCreateDescriptorSetLayout(device, &layout_info, null, &layout);
    if (!vk.succeeded(result)) return LayoutError.DescriptorSetLayoutCreationFailed;

    std.debug.assert(layout != null);
    return layout;
}
