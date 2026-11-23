const std = @import("std");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");

const assert = std.debug.assert;

const descriptor_set_count_frame: u32 = 1;

pub const atlas_binding_count: u32 = 3;

const storage_binding_count: u32 = vk_types.frame_buffer_count;
const uniform_binding: u32 = storage_binding_count;
const atlas_binding_first: u32 = uniform_binding + 1;
const sampler_binding: u32 = atlas_binding_first + atlas_binding_count;
const binding_count: u32 = sampler_binding + 1;

comptime {
    assert(uniform_binding == 5);
    assert(atlas_binding_first == 6);
    assert(sampler_binding == 9);
}

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

pub fn createFrameLayout(device: vk.Device) LayoutError!vk.DescriptorSetLayout {
    assert(device != null);
    var bindings: [binding_count]vk.DescriptorSetLayoutBinding = undefined;
    for (&bindings, 0..) |*binding, index| {
        const slot: u32 = @intCast(index);
        const kind: vk.DescriptorType = if (slot < uniform_binding)
            vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        else if (slot == uniform_binding)
            vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        else if (slot < sampler_binding)
            vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
        else
            vk.VK_DESCRIPTOR_TYPE_SAMPLER;
        binding.* = .{
            .binding = slot,
            .descriptorType = kind,
            .descriptorCount = 1,
            .stageFlags = if (slot <= uniform_binding)
                vk.VK_SHADER_STAGE_VERTEX_BIT
            else
                vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
    }
    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = binding_count,
        .pBindings = &bindings,
    };
    var layout: vk.DescriptorSetLayout = null;
    const result = vk.vkCreateDescriptorSetLayout(device, &layout_info, null, &layout);
    if (!vk.succeeded(result)) return LayoutError.DescriptorSetLayoutCreationFailed;
    assert(layout != null);
    return layout;
}

pub fn createDescriptorPool(device: vk.Device, frame_count: u32) PoolError!vk.DescriptorPool {
    assert(device != null);
    assert(frame_count >= 1);
    assert(frame_count <= vk_types.frame_count_max);

    const sets = descriptor_set_count_frame * frame_count;
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = storage_binding_count * sets,
        },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = sets },
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = atlas_binding_count * sets,
        },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = sets },
    };

    const pool_info = vk.DescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = sets,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    var pool: vk.DescriptorPool = null;
    const result = vk.vkCreateDescriptorPool(device, &pool_info, null, &pool);
    if (!vk.succeeded(result)) return PoolError.DescriptorPoolCreationFailed;

    assert(pool != null);
    return pool;
}

pub fn allocateDescriptorSet(
    device: vk.Device,
    pool: vk.DescriptorPool,
    layout: vk.DescriptorSetLayout,
) AllocError!vk.DescriptorSet {
    assert(device != null);
    assert(pool != null);
    assert(layout != null);

    const layouts = [_]vk.DescriptorSetLayout{layout};
    const alloc_info = vk.DescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layouts,
    };

    var descriptor_set: vk.DescriptorSet = null;
    const result = vk.vkAllocateDescriptorSets(device, &alloc_info, (&descriptor_set)[0..1]);
    if (!vk.succeeded(result)) return AllocError.DescriptorSetAllocationFailed;

    assert(descriptor_set != null);
    return descriptor_set;
}

pub const FrameBindings = struct {
    storage: [storage_binding_count]vk.DescriptorBufferInfo,
    uniform: vk.Buffer,
    atlas_views: [atlas_binding_count]vk.ImageView,
    sampler: vk.Sampler,
};

pub fn updateFrameDescriptorSet(
    device: vk.Device,
    descriptor_set: vk.DescriptorSet,
    bindings: *const FrameBindings,
) void {
    assert(device != null);
    assert(descriptor_set != null);
    assert(bindings.uniform != null);
    assert(bindings.sampler != null);

    const uniform_info = vk.DescriptorBufferInfo{
        .buffer = bindings.uniform,
        .offset = 0,
        .range = @sizeOf(vk_types.Uniforms),
    };
    var image_infos: [atlas_binding_count]vk.DescriptorImageInfo = undefined;
    for (&image_infos, bindings.atlas_views) |*info, view| {
        assert(view != null);
        info.* = .{
            .sampler = null,
            .imageView = view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }
    const sampler_info = vk.DescriptorImageInfo{
        .sampler = bindings.sampler,
        .imageView = null,
        .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var writes: [binding_count]vk.WriteDescriptorSet = undefined;
    for (&writes, 0..) |*write, index| {
        const slot: u32 = @intCast(index);
        write.* = .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = slot,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        if (slot < uniform_binding) {
            assert(bindings.storage[slot].buffer != null);
            write.pBufferInfo = bindings.storage[slot..][0..1];
        } else if (slot == uniform_binding) {
            write.descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            write.pBufferInfo = (&uniform_info)[0..1];
        } else if (slot < sampler_binding) {
            write.descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            write.pImageInfo = image_infos[slot - atlas_binding_first ..][0..1];
        } else {
            write.descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER;
            write.pImageInfo = (&sampler_info)[0..1];
        }
    }
    vk.vkUpdateDescriptorSets(device, binding_count, &writes, 0, null);
}

pub fn createAtlasSampler(device: vk.Device) SamplerError!vk.Sampler {
    assert(device != null);

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

    assert(sampler != null);
    return sampler;
}
