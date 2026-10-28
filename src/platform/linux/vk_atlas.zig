//! Atlas texture management for Vulkan renderer.
//!
//! One generic implementation, parameterized by pixel format, serves all three
//! atlases (text, SVG, image). Each atlas image is created once at init at its
//! `AtlasLimits` size and never recreated (CLAUDE.md §2). The renderer keeps no
//! CPU copy of atlas pixels: each frame it copies the records its window has not
//! uploaded from the shared `AtlasUploads` journal into its staging lane, and
//! records one barrier, one batched copy, and one barrier per changed atlas.
//!
//! Axes of variation across the three atlases:
//!   1. Pixel format — R8 (text) vs RGBA8 (SVG, image)
//!   2. Which AtlasResources instance to target
//!   3. Which descriptor set / storage buffer to bind

const std = @import("std");
const vk = @import("vulkan.zig");

// =============================================================================
// Limits (CLAUDE.md Rule #4)
// =============================================================================

/// Regions recorded per `vkCmdCopyBufferToImage` call; larger batches split.
pub const copy_region_count_max: u32 = 64;

// =============================================================================
// Public Types
// =============================================================================

/// Pixel format for atlas textures. Determines Vulkan format and byte stride.
pub const AtlasFormat = enum {
    /// Single-channel (text atlas): 1 byte per pixel, VK_FORMAT_R8_UNORM.
    r8,
    /// Four-channel (SVG/image atlas): 4 bytes per pixel, VK_FORMAT_R8G8B8A8_UNORM.
    rgba8,

    pub fn vkFormat(self: AtlasFormat) vk.Format {
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

/// All Vulkan resources for a single atlas texture.
/// Groups the 7 per-atlas fields, so three atlases are 3 structs, not 21 fields.
pub const AtlasResources = struct {
    image: vk.Image = null,
    memory: vk.DeviceMemory = null,
    view: vk.ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    format: AtlasFormat = .r8,
    /// False until the first upload moves the image out of `UNDEFINED`.
    layout_ready: bool = false,

    /// Destroy all Vulkan objects owned by this atlas. Safe with null handles.
    pub fn destroy(self: *AtlasResources, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.view) |v| vk.vkDestroyImageView(device, v, null);
        if (self.image) |i| vk.vkDestroyImage(device, i, null);
        if (self.memory) |m| vk.vkFreeMemory(device, m, null);
        self.* = .{};
    }
};

pub const AtlasError = error{
    AtlasImageCreationFailed,
    AtlasMemoryAllocationFailed,
    AtlasImageViewCreationFailed,
    NoSuitableMemoryType,
};

// =============================================================================
// Public API
// =============================================================================

/// Update a textured pipeline's descriptor set (storage + uniform + atlas + sampler).
///
/// Serves the text, SVG, and image pipelines, which differ only in which
/// descriptor set, storage buffer, and atlas view to use.
pub fn updateAtlasDescriptorSet(
    device: vk.Device,
    descriptor_set: vk.DescriptorSet,
    storage_buffer: vk.Buffer,
    storage_range: vk.DeviceSize,
    uniform_buffer: vk.Buffer,
    atlas_view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    std.debug.assert(device != null);
    std.debug.assert(atlas_view != null and sampler != null);

    const buffer_infos = [_]vk.DescriptorBufferInfo{
        .{
            .buffer = storage_buffer,
            .offset = 0,
            .range = storage_range,
        },
        .{
            .buffer = uniform_buffer,
            .offset = 0,
            .range = @sizeOf(@import("vk_types.zig").Uniforms),
        },
    };

    const image_info = vk.DescriptorImageInfo{
        .sampler = null,
        .imageView = atlas_view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    const sampler_info = vk.DescriptorImageInfo{
        .sampler = sampler,
        .imageView = null,
        .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    const writes = descriptorWrites(descriptor_set, &buffer_infos, &image_info, &sampler_info);
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

// =============================================================================
// Public API — Atlas images and batched uploads
// =============================================================================

/// Create an atlas image at its budget size. Called once at init; the image is
/// never recreated. Its contents start undefined: every uploaded item carries
/// its own zero border, and nothing outside items is ever sampled.
pub fn createAtlas(
    resources: *AtlasResources,
    size: u32,
    format: AtlasFormat,
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!void {
    std.debug.assert(size > 0);
    std.debug.assert(resources.image == null);
    try createAtlasImage(device, resources, size, size, format, mem_properties);
    resources.format = format;
    resources.layout_ready = false;
    std.debug.assert(resources.view != null);
}

/// Record one atlas's uploads for this frame: a barrier into `TRANSFER_DST`, the
/// copies in batches of `copy_region_count_max`, and a barrier back to shader
/// reads. Regions never overlap: the atlas does not reuse a region until every
/// renderer has uploaded the records written into it.
///
/// The first upload transitions from `UNDEFINED`, which discards nothing that
/// was ever written; later uploads preserve the existing contents.
pub fn recordAtlasCopies(
    cmd: vk.CommandBuffer,
    resources: *AtlasResources,
    staging_buffer: vk.Buffer,
    regions: []const vk.BufferImageCopy,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(resources.image != null);
    std.debug.assert(staging_buffer != null);
    if (regions.len == 0) return;

    // The first upload discards the image's undefined contents; later ones
    // wait for the previous frames' shader reads and keep the pixels.
    const from = if (resources.layout_ready) &sampled_state else &undefined_state;
    recordBarrier(cmd, resources.image, from, &transfer_state);

    var start: usize = 0;
    while (start < regions.len) {
        const count = @min(regions.len - start, copy_region_count_max);
        vk.vkCmdCopyBufferToImage(
            cmd,
            staging_buffer,
            resources.image,
            transfer_state.layout,
            @intCast(count),
            regions[start..].ptr,
        );
        start += count;
    }
    std.debug.assert(start == regions.len);

    recordBarrier(cmd, resources.image, &transfer_state, &sampled_state);
    resources.layout_ready = true;
}

/// The copy region for one staged record at `staging_offset` in the buffer.
pub fn copyRegion(
    staging_offset: vk.DeviceSize,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) vk.BufferImageCopy {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    return .{
        .bufferOffset = staging_offset,
        .bufferRowLength = 0, // tightly packed (row length = imageExtent.width)
        .bufferImageHeight = 0, // tightly packed (height = imageExtent.height)
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
}

/// One side of an atlas image barrier: the stage and access that last touched
/// (or will next touch) the image, and its layout.
const ImageState = struct {
    stage: u32,
    access: u32,
    layout: vk.ImageLayout,
};

/// A freshly created image: no prior access, contents discarded.
const undefined_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    .access = 0,
    .layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
};

/// Written by a buffer copy.
const transfer_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    .access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
    .layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
};

/// Sampled by the text, SVG and image fragment shaders.
const sampled_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    .access = vk.VK_ACCESS_SHADER_READ_BIT,
    .layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

const color_range = vk.ImageSubresourceRange{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .baseMipLevel = 0,
    .levelCount = 1,
    .baseArrayLayer = 0,
    .layerCount = 1,
};

// =============================================================================
// Internal — Image Creation
// =============================================================================

/// Create a Vulkan image + device memory + image view for an atlas.
fn createAtlasImage(
    device: vk.Device,
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!void {
    std.debug.assert(device != null);
    std.debug.assert(resources.image == null); // Must be destroyed first

    const vk_fmt = format.vkFormat();

    // Create image
    resources.image = try createImage(device, width, height, vk_fmt);
    errdefer {
        vk.vkDestroyImage(device, resources.image, null);
        resources.image = null;
    }

    // Allocate and bind memory
    resources.memory = try allocateImageMemory(device, resources.image, mem_properties);
    errdefer {
        vk.vkFreeMemory(device, resources.memory, null);
        resources.memory = null;
    }
    _ = vk.vkBindImageMemory(device, resources.image, resources.memory, 0);

    // Create image view
    resources.view = try createImageView(device, resources.image, vk_fmt);
    errdefer {
        vk.vkDestroyImageView(device, resources.view, null);
        resources.view = null;
    }

    resources.width = width;
    resources.height = height;
}

fn createImage(device: vk.Device, width: u32, height: u32, format: vk.Format) AtlasError!vk.Image {
    std.debug.assert(device != null);
    std.debug.assert(width > 0 and height > 0);

    const info = vk.ImageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var image: vk.Image = null;
    if (!vk.succeeded(vk.vkCreateImage(device, &info, null, &image))) {
        return AtlasError.AtlasImageCreationFailed;
    }
    std.debug.assert(image != null);
    return image;
}

fn allocateImageMemory(
    device: vk.Device,
    image: vk.Image,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!vk.DeviceMemory {
    std.debug.assert(device != null);
    std.debug.assert(image != null);

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &reqs);

    const type_index = vk.findMemoryType(
        mem_properties,
        reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse return AtlasError.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = type_index,
    };

    var memory: vk.DeviceMemory = null;
    if (!vk.succeeded(vk.vkAllocateMemory(device, &alloc_info, null, &memory))) {
        return AtlasError.AtlasMemoryAllocationFailed;
    }
    std.debug.assert(memory != null);
    return memory;
}

fn createImageView(device: vk.Device, image: vk.Image, format: vk.Format) AtlasError!vk.ImageView {
    std.debug.assert(device != null);
    std.debug.assert(image != null);

    const view_info = vk.ImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var view: vk.ImageView = null;
    if (!vk.succeeded(vk.vkCreateImageView(device, &view_info, null, &view))) {
        return AtlasError.AtlasImageViewCreationFailed;
    }
    return view;
}

fn recordBarrier(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    from: *const ImageState,
    to: *const ImageState,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(to.layout != vk.VK_IMAGE_LAYOUT_UNDEFINED);
    const barrier = vk.ImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = from.access,
        .dstAccessMask = to.access,
        .oldLayout = from.layout,
        .newLayout = to.layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = color_range,
    };
    vk.vkCmdPipelineBarrier(cmd, from.stage, to.stage, 0, 0, null, 0, null, 1, (&barrier)[0..1]);
}

// =============================================================================
// Internal — Descriptor Writes
// =============================================================================

/// Build the 4-write descriptor update array. Shared layout:
///   binding 0: storage buffer (glyph/svg/image instance data)
///   binding 1: uniform buffer (viewport dimensions)
///   binding 2: sampled image  (atlas texture)
///   binding 3: sampler
fn descriptorWrites(
    set: vk.DescriptorSet,
    buffer_infos: *const [2]vk.DescriptorBufferInfo,
    image_info: *const vk.DescriptorImageInfo,
    sampler_info: *const vk.DescriptorImageInfo,
) [4]vk.WriteDescriptorSet {
    return .{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = buffer_infos[0..1],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = buffer_infos[1..2],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .pImageInfo = image_info[0..1],
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 3,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
            .pImageInfo = sampler_info[0..1],
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };
}
