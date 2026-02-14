//! Atlas texture management for Vulkan renderer.
//!
//! Replaces three copy-pasted atlas upload paths (text, SVG, image) with a
//! single generic implementation parameterized by pixel format. Each atlas
//! follows the same lifecycle: create image → stage data → barrier → copy →
//! barrier → submit → wait → update descriptor set.
//!
//! Axes of variation across the three original paths:
//!   1. Pixel format — R8 (text) vs RGBA8 (SVG, image)
//!   2. Which AtlasResources instance to target
//!   3. Which descriptor set / storage buffer to bind
//!
//! Everything else (image creation, staging, barriers, submit) is identical.

const std = @import("std");
const vk = @import("vulkan.zig");

// =============================================================================
// Limits (CLAUDE.md Rule #4)
// =============================================================================

/// Maximum atlas dimension in either axis (4096×4096 = 64MB RGBA).
pub const MAX_ATLAS_DIMENSION: u32 = 8192;

/// Maximum staging size for a single atlas region (RGBA at max dimension).
pub const MAX_SINGLE_ATLAS_BYTES: vk.DeviceSize = MAX_ATLAS_DIMENSION * MAX_ATLAS_DIMENSION * 4;

/// Number of atlas staging regions (text, SVG, image).
pub const STAGING_REGION_COUNT: u32 = 3;

/// Total staging buffer size: 3 regions so batched uploads can stage all atlases
/// simultaneously without clobbering (CLAUDE.md Rule #4 — put a limit on everything).
/// Each `vkCmdCopyBufferToImage` reads from a non-overlapping region.
pub const MAX_STAGING_BYTES: vk.DeviceSize = MAX_SINGLE_ATLAS_BYTES * STAGING_REGION_COUNT;

/// Legacy alias used by ensureStagingCapacity for single-shot uploads.
const MAX_STAGING_BYTES_SINGLE: vk.DeviceSize = MAX_SINGLE_ATLAS_BYTES;

// =============================================================================
// Public Types
// =============================================================================

/// Pixel format for atlas textures. Determines Vulkan format and byte stride.
pub const AtlasFormat = enum {
    /// Single-channel (text atlas): 1 byte per pixel, VK_FORMAT_R8_UNORM.
    r8,
    /// Four-channel (SVG/image atlas): 4 bytes per pixel, VK_FORMAT_R8G8B8A8_UNORM.
    rgba8,

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

/// All Vulkan resources for a single atlas texture.
/// Replaces 7 individual fields per atlas (21 total → 3 structs).
pub const AtlasResources = struct {
    image: vk.Image = null,
    memory: vk.DeviceMemory = null,
    view: vk.ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 0,

    /// Destroy all Vulkan objects owned by this atlas. Safe with null handles.
    pub fn destroy(self: *AtlasResources, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.view) |v| vk.vkDestroyImageView(device, v, null);
        if (self.image) |i| vk.vkDestroyImage(device, i, null);
        if (self.memory) |m| vk.vkFreeMemory(device, m, null);
        self.* = .{};
    }
};

/// Groups the mutable staging buffer state and immutable transfer
/// synchronization primitives needed by atlas upload operations.
/// Constructed on the stack from VulkanRenderer fields at each call site.
pub const TransferContext = struct {
    // Staging buffer state (mutable — may be resized)
    staging_buffer: *vk.Buffer,
    staging_memory: *vk.DeviceMemory,
    staging_mapped: *?*anyopaque,
    staging_size: *vk.DeviceSize,
    // Transfer synchronization (immutable per-call)
    transfer_command_buffer: vk.CommandBuffer,
    transfer_fence: vk.Fence,
    graphics_queue: vk.Queue,
    // Device context
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
};

pub const AtlasError = error{
    AtlasImageCreationFailed,
    AtlasMemoryAllocationFailed,
    AtlasImageViewCreationFailed,
    NoSuitableMemoryType,
    StagingBufferCreationFailed,
    StagingMemoryAllocationFailed,
};

// =============================================================================
// Public API
// =============================================================================

/// Upload atlas data, recreating the image if dimensions changed.
///
/// Returns `true` if the image was (re)created — caller should update
/// the corresponding descriptor set via `updateAtlasDescriptorSet`.
/// Returns `false` if only the pixel data was refreshed (same dimensions).
pub fn uploadAtlas(
    resources: *AtlasResources,
    data: []const u8,
    width: u32,
    height: u32,
    format: AtlasFormat,
    transfer: *TransferContext,
) AtlasError!bool {
    std.debug.assert(width > 0 and width <= MAX_ATLAS_DIMENSION);
    std.debug.assert(height > 0 and height <= MAX_ATLAS_DIMENSION);

    const bpp = format.bytesPerPixel();
    std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * bpp);

    const same_size = resources.width == width and
        resources.height == height and
        resources.image != null;

    if (!same_size) {
        // Destroy old resources and create new image at new dimensions
        resources.destroy(transfer.device);
        try createAtlasImage(transfer.device, resources, width, height, format, transfer.mem_properties);
    }

    try uploadAtlasData(resources, data, width, height, format, transfer);
    return !same_size;
}

/// Update a textured pipeline's descriptor set (storage + uniform + atlas + sampler).
///
/// Replaces updateTextDescriptorSet, updateSvgDescriptorSet, and
/// updateImageDescriptorSet — three identical ~80-line functions whose only
/// differences were which descriptor set, storage buffer, and atlas view to use.
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
// Public API — Batched Atlas Uploads
// =============================================================================

/// Prepare an atlas for batched upload: (re)create image if dimensions changed,
/// then copy pixel data into the staging buffer at `staging_offset`.
///
/// Does NOT record or submit any command buffer — the caller batches all
/// pending transfers into a single submission via `recordAtlasTransfer`.
///
/// Returns `true` if the image was (re)created (caller must update descriptors).
pub fn prepareAtlasUpload(
    resources: *AtlasResources,
    data: []const u8,
    width: u32,
    height: u32,
    format: AtlasFormat,
    transfer: *TransferContext,
    staging_offset: vk.DeviceSize,
) AtlasError!bool {
    std.debug.assert(width > 0 and width <= MAX_ATLAS_DIMENSION);
    std.debug.assert(height > 0 and height <= MAX_ATLAS_DIMENSION);

    const bpp = format.bytesPerPixel();
    const expected_len = @as(usize, width) * @as(usize, height) * bpp;
    std.debug.assert(data.len == expected_len);

    // Assert staging region fits within the pre-allocated staging buffer
    std.debug.assert(staging_offset + @as(vk.DeviceSize, @intCast(data.len)) <= transfer.staging_size.*);

    const same_size = resources.width == width and
        resources.height == height and
        resources.image != null;

    if (!same_size) {
        resources.destroy(transfer.device);
        try createAtlasImage(transfer.device, resources, width, height, format, transfer.mem_properties);
    }

    // Copy pixel data into staging buffer at the designated region offset
    if (transfer.staging_mapped.*) |ptr| {
        const base: [*]u8 = @ptrCast(ptr);
        const offset: usize = @intCast(staging_offset);
        @memcpy(base[offset..][0..data.len], data);
    }

    resources.generation += 1;
    return !same_size;
}

/// Record atlas transfer commands (barrier → copy → barrier) into an
/// already-begun command buffer.
///
/// Reads pixel data from `staging_buffer` at `staging_offset`. The caller
/// is responsible for beginning/ending the command buffer and submitting it.
/// Multiple calls to this function batch all atlas transfers into one submit.
pub fn recordAtlasTransfer(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    staging_buffer: vk.Buffer,
    staging_offset: vk.DeviceSize,
    width: u32,
    height: u32,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(image != null);
    std.debug.assert(staging_buffer != null);
    std.debug.assert(width > 0 and height > 0);

    // Transition: undefined → transfer dst
    recordBarrier(
        cmd,
        image,
        0,
        vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    );

    // Copy staging buffer → image (at the designated region offset)
    const region = vk.BufferImageCopy{
        .bufferOffset = staging_offset,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    vk.vkCmdCopyBufferToImage(cmd, staging_buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    // Transition: transfer dst → shader read
    recordBarrier(
        cmd,
        image,
        vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        vk.VK_ACCESS_SHADER_READ_BIT,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    );
}

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

fn createImage(device: vk.Device, width: u32, height: u32, format: c_uint) AtlasError!vk.Image {
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

fn createImageView(device: vk.Device, image: vk.Image, format: c_uint) AtlasError!vk.ImageView {
    std.debug.assert(device != null);
    std.debug.assert(image != null);

    const info = vk.ImageViewCreateInfo{
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
    if (!vk.succeeded(vk.vkCreateImageView(device, &info, null, &view))) {
        return AtlasError.AtlasImageViewCreationFailed;
    }
    std.debug.assert(view != null);
    return view;
}

// =============================================================================
// Internal — Staging Upload
// =============================================================================

/// Upload pixel data to an existing atlas image via staging buffer + transfer.
fn uploadAtlasData(
    resources: *AtlasResources,
    data: []const u8,
    width: u32,
    height: u32,
    format: AtlasFormat,
    transfer: *TransferContext,
) AtlasError!void {
    std.debug.assert(resources.image != null);
    std.debug.assert(transfer.transfer_command_buffer != null);
    std.debug.assert(transfer.transfer_fence != null);

    const image_size_bytes: vk.DeviceSize = @intCast(
        @as(u64, width) * @as(u64, height) * format.bytesPerPixel(),
    );

    // Ensure staging buffer is large enough
    try ensureStagingCapacity(transfer, image_size_bytes);

    // Copy pixel data into staging buffer
    if (transfer.staging_mapped.*) |ptr| {
        const dest: [*]u8 = @ptrCast(ptr);
        @memcpy(dest[0..data.len], data);
    }

    // Record and submit transfer commands
    recordTransferCommands(transfer.transfer_command_buffer, resources.image, transfer.staging_buffer.*, width, height);
    submitTransfer(transfer);

    resources.generation += 1;
}

/// Ensure staging buffer can hold `required_bytes`. Recreates if too small.
fn ensureStagingCapacity(transfer: *TransferContext, required_bytes: vk.DeviceSize) AtlasError!void {
    std.debug.assert(required_bytes > 0);
    std.debug.assert(required_bytes <= MAX_STAGING_BYTES_SINGLE);

    if (transfer.staging_buffer.* != null and transfer.staging_size.* >= required_bytes) {
        return; // Already big enough
    }

    // Destroy old staging buffer if any
    if (transfer.staging_buffer.*) |buf| {
        vk.vkDestroyBuffer(transfer.device, buf, null);
    }
    if (transfer.staging_memory.*) |mem| {
        vk.vkUnmapMemory(transfer.device, mem);
        vk.vkFreeMemory(transfer.device, mem, null);
    }

    // Create new staging buffer
    try createStagingBuffer(
        transfer.device,
        required_bytes,
        transfer.mem_properties,
        transfer.staging_buffer,
        transfer.staging_memory,
    );

    _ = vk.vkMapMemory(
        transfer.device,
        transfer.staging_memory.*,
        0,
        required_bytes,
        0,
        transfer.staging_mapped,
    );
    transfer.staging_size.* = required_bytes;
}

fn createStagingBuffer(
    device: vk.Device,
    size: vk.DeviceSize,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    out_buffer: *vk.Buffer,
    out_memory: *vk.DeviceMemory,
) AtlasError!void {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);

    const buf_info = vk.BufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    if (!vk.succeeded(vk.vkCreateBuffer(device, &buf_info, null, out_buffer))) {
        return AtlasError.StagingBufferCreationFailed;
    }

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, out_buffer.*, &reqs);

    const type_index = vk.findMemoryType(
        mem_properties,
        reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    ) orelse return AtlasError.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = type_index,
    };

    if (!vk.succeeded(vk.vkAllocateMemory(device, &alloc_info, null, out_memory))) {
        return AtlasError.StagingMemoryAllocationFailed;
    }

    _ = vk.vkBindBufferMemory(device, out_buffer.*, out_memory.*, 0);
}

// =============================================================================
// Internal — Command Recording
// =============================================================================

/// Record barrier → copy → barrier into the transfer command buffer.
fn recordTransferCommands(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    staging_buffer: vk.Buffer,
    width: u32,
    height: u32,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(image != null);

    _ = vk.vkResetCommandBuffer(cmd, 0);

    const begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

    // Transition: undefined → transfer dst
    recordBarrier(cmd, image, 0, vk.VK_ACCESS_TRANSFER_WRITE_BIT, vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT);

    // Copy staging buffer → image
    const region = vk.BufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    vk.vkCmdCopyBufferToImage(cmd, staging_buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    // Transition: transfer dst → shader read
    recordBarrier(cmd, image, vk.VK_ACCESS_TRANSFER_WRITE_BIT, vk.VK_ACCESS_SHADER_READ_BIT, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

    _ = vk.vkEndCommandBuffer(cmd);
}

fn recordBarrier(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    src_access: u32,
    dst_access: u32,
    old_layout: c_uint,
    new_layout: c_uint,
    src_stage: u32,
    dst_stage: u32,
) void {
    const barrier = vk.ImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
}

/// Submit the transfer command buffer and wait for completion.
fn submitTransfer(transfer: *TransferContext) void {
    std.debug.assert(transfer.transfer_command_buffer != null);
    std.debug.assert(transfer.transfer_fence != null);
    std.debug.assert(transfer.graphics_queue != null);

    _ = vk.vkResetFences(transfer.device, 1, &transfer.transfer_fence);

    const cmd = transfer.transfer_command_buffer;
    const submit_info = vk.SubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };

    _ = vk.vkQueueSubmit(transfer.graphics_queue, 1, &submit_info, transfer.transfer_fence);
    _ = vk.vkWaitForFences(transfer.device, 1, &transfer.transfer_fence, vk.TRUE, std.math.maxInt(u64));
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
            .pBufferInfo = &buffer_infos[0],
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
            .pBufferInfo = &buffer_infos[1],
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
            .pImageInfo = image_info,
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
            .pImageInfo = sampler_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };
}
